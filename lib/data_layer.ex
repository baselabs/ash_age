defmodule AshAge.DataLayer do
  @moduledoc """
  Ash DataLayer for Apache AGE graph database.

  Stores Ash resources as vertices in an AGE graph within PostgreSQL.
  Uses the existing Ecto.Repo connection pool — no new database driver.
  All dynamic values use parameterized queries for safety.

  ## DSL

  ```elixir
  use Ash.Resource,
    data_layer: AshAge.DataLayer

  age do
    graph :my_graph
    repo MyApp.Repo
    label :MyLabel     # optional, defaults to the module's short name
    skip [:computed]   # optional, attributes excluded from AGE properties
    sensitive [:ssn]   # optional, classified attributes (binary-storage or skipped)
    rls_guc "myapp.tenant_id"  # optional, :attribute-only DB-enforced RLS backstop
    # tenant_graph {MyApp.Graphs, :for_tenant, []}  # optional, :context graph-name override

    edge :related_to do
      label :RELATES_TO
      direction :outgoing
      destination MyApp.OtherResource
    end
  end
  ```

  ## Capabilities

  Supports `:read`, `:create`, `:update`, `:destroy`, `:bulk_create`, `:filter`
  (eq/not_eq/gt/lt/gte/lte/in/is_nil, boolean and nested expressions),
  `:sort`, `:limit`, `:offset`, `:transact`, `:multitenancy` (`:attribute` and
  `:context`), `:composite_primary_key`, and `:changeset_filter`. Not supported:
  `:upsert`, aggregates, and lateral joins. One subtlety: binary-storage
  attributes are **unsortable** (`can?({:sort, :binary})` is `false`) because
  the stored `$age64$`-tagged base64 form is not byte-order-preserving —
  sorting on one raises `Ash.Error.Query.UnsortableField` at query build.

  ## Pagination

  Both Ash pagination strategies work: **offset** (`SKIP .. LIMIT ..`) and
  **keyset**. Keyset is supported *without* a native data-layer keyset
  capability — `can?(:keyset)` is intentionally not declared, so
  `Ash.Actions.Read.use_data_layer_keyset?/2` returns `false` and Ash takes
  its rewrite branch: it over-fetches by `limit + 1` and rewrites
  `page: [after: <keyset>]` into a compound sort + filter expression
  (`(rank > $x) OR (rank = $x AND id > $y)`, fully parameterized) built only
  from the comparison and boolean operators AshAge already supports. The
  practical win: keyset pages cost a constant-time `WHERE` filter instead of
  the O(page_offset) walk-and-discard deep `SKIP N` pages impose on the AGE
  planner. Binary-storage attributes are not keyset-sortable for the same
  reason they are not sortable (see above) — sort on a non-binary attribute.
  """

  @age %Spark.Dsl.Section{
    name: :age,
    describe: "Configuration for the AGE graph data layer",
    schema: [
      graph: [
        type: :atom,
        required: true,
        doc: "The AGE graph name (must be a valid identifier)"
      ],
      repo: [
        type: :atom,
        required: true,
        doc: "The Ecto.Repo module to use for database access"
      ],
      label: [
        type: {:or, [:atom, :string]},
        doc: "Vertex label in the graph. Defaults to the resource's short module name."
      ],
      skip: [
        type: {:list, :atom},
        default: [],
        doc: "List of attribute names to exclude from AGE vertex properties"
      ],
      sensitive: [
        type: {:list, :atom},
        default: [],
        doc:
          "Attribute names classified as sensitive. Fail-closed verifier check " <>
            "(AshAge.DataLayer.Verifiers.ValidateSensitive): each must be " <>
            "binary-storage-typed (app-side-encrypted bytes) or listed in `skip`. " <>
            "ash_age verifies the type SHAPE — encrypting is the host app's job. " <>
            "Verifier errors are compiler diagnostics; build with " <>
            "--warnings-as-errors to make them blocking."
      ],
      tenant_graph: [
        type: :mfa,
        doc:
          "MFA applied as `apply(m, f, [tenant | a])` returning the AGE graph name " <>
            "for a :context tenant. Defaults to a built-in collision-free encoder."
      ],
      rls_guc: [
        type: :string,
        doc:
          "Opt into DB-enforced RLS: the PostgreSQL custom GUC (e.g. \"ash_age.tenant_id\") " <>
            "ash_age sets per read/write so RLS policies scope by tenant. `:attribute` only."
      ]
    ],
    entities: [
      %Spark.Dsl.Entity{
        name: :edge,
        describe: "Defines an edge mapping from this vertex to another",
        args: [:name],
        target: AshAge.Edge,
        schema: [
          name: [
            type: :atom,
            required: true,
            doc: "Relationship name (must match an Ash relationship)"
          ],
          label: [
            type: :atom,
            required: true,
            doc: "Edge label in the graph (e.g., :RELATES_TO)"
          ],
          direction: [
            type: {:one_of, [:outgoing, :incoming, :both]},
            default: :outgoing,
            doc: "Edge direction"
          ],
          destination: [
            type: :atom,
            required: true,
            doc: "Destination resource module"
          ],
          properties: [
            type: {:list, :atom},
            default: [],
            doc: "Optional edge property keys, set from same-named action arguments."
          ]
        ]
      }
    ]
  }

  @behaviour Ash.DataLayer

  alias Ash.Actions.Helpers.Bulk, as: BulkHelpers
  alias Ash.Error.Changes.StaleRecord
  alias AshAge.Cypher.Expr
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer.Info
  alias AshAge.Errors.{CreateFailed, QueryFailed, UnsupportedFilter, UpdateFailed}
  alias AshAge.Query.Filter
  alias AshAge.Telemetry
  alias AshAge.Type.{Agtype, Cast}
  alias Ecto.Adapters.SQL
  alias Ecto.Schema.Metadata

  use Spark.Dsl.Extension,
    sections: [@age],
    transformers: [
      AshAge.DataLayer.Transformers.ValidateGraph,
      AshAge.DataLayer.Transformers.EnsureLabelled,
      AshAge.DataLayer.Transformers.ValidateLabelFormat,
      AshAge.DataLayer.Transformers.DefaultRelate
    ],
    verifiers: [
      AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr,
      AshAge.DataLayer.Verifiers.ValidateEdge,
      AshAge.DataLayer.Verifiers.ValidateSensitive,
      AshAge.DataLayer.Verifiers.ValidateSkip
    ]

  # === Capability Declarations ===

  @impl true
  def can?(_, :read), do: true
  def can?(_, :create), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :transact), do: true
  def can?(_, :filter), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, :sort), do: true
  # Ash asks {:sort, Ash.Type.storage_type(type)} (deps/ash sort.ex): binary
  # storage is stored as tagged base64, which is not byte-order-preserving, so
  # sorting it would return a silently wrong order. Rejecting here surfaces
  # Ash.Error.Query.UnsortableField at query build.
  def can?(_, {:sort, :binary}), do: false
  def can?(_, {:sort, _}), do: true
  def can?(_, {:filter_operator, :eq}), do: true
  def can?(_, {:filter_operator, :not_eq}), do: true
  def can?(_, {:filter_operator, :gt}), do: true
  def can?(_, {:filter_operator, :lt}), do: true
  def can?(_, {:filter_operator, :gte}), do: true
  def can?(_, {:filter_operator, :lte}), do: true
  def can?(_, {:filter_operator, :in}), do: true
  def can?(_, {:filter_operator, :is_nil}), do: true
  def can?(_, {:filter_operator, _}), do: false
  def can?(_, {:filter_expr, %Ash.Query.Operator.Eq{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.NotEq{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.In{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.IsNil{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.GreaterThan{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.LessThan{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.GreaterThanOrEqual{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Operator.LessThanOrEqual{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.BooleanExpression{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Not{}}), do: true

  # Ash wraps atomic exprs on `allow_nil?: false` attrs with a validation:
  # `if is_nil(type(expr, Type, [])) do error(...) else expr end`. AGE is
  # dynamically typed, so `type/3` unwraps to its inner expr; `error/2` emits
  # null (its branch only fires when the expr yields nil — a documented gap:
  # allow_nil? on atomic results isn't DB-enforced for AGE, same class as the
  # no-PK-uniqueness reality). Without these, Ash rejects every atomic update on
  # a non-nil attr as `{:not_atomic, "does not support the function type(...)"}`.
  def can?(_, {:filter_expr, %Ash.Query.Function.Type{}}), do: true
  def can?(_, {:filter_expr, %Ash.Query.Function.Error{}}), do: true
  def can?(_, {:filter_expr, _}), do: false
  # Pure capability flag (no callback) gating the atomic-batches destroy path's
  # field-select branch (destroy/bulk.ex:657). Declaring true lets Ash compute a
  # tight select list; false falls back to all attrs. Either works; true matches
  # the path Ash now takes since :update_query+:expr_error reroute bulk_destroy
  # to do_atomic_destroy.
  def can?(_, :action_select), do: true
  def can?(_, :upsert), do: true
  def can?(_, :bulk_create), do: true
  def can?(_, :destroy_query), do: true
  def can?(_, {:lateral_join, _}), do: false
  # Aggregates (Slice A): count/sum/avg/min/max/exists over the resource's own
  # records (no relationship path). A no-path aggregate is `is_unrelated?` in Ash
  # (`query.ex:3507-3510`), which requires BOTH `{:aggregate, kind}` AND
  # `{:aggregate, :unrelated}` — declaring only the former rejects every aggregate
  # at `Ash.Query` build (AggregatesNotSupported). `{:query_aggregate, kind}` gates
  # `Ash.aggregate/3` and countable pagination (`aggregate.ex:215`,
  # `set_primary_actions.ex:148`) — delegate to the kind whitelist.
  def can?(_, {:aggregate, kind})
      when kind in [:count, :sum, :avg, :min, :max, :exists],
      do: true

  def can?(_, {:aggregate, :unrelated}), do: true
  def can?(resource, {:query_aggregate, kind}), do: can?(resource, {:aggregate, kind})
  def can?(_, :aggregate_filter), do: true
  # first/list/custom/relationship-pathed aggregates are not supported (AGE has no
  # documented list aggregate; relationship aggregates compose Traverse — follow-on).
  def can?(_, {:aggregate, _}), do: false
  def can?(_, :multitenancy), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :changeset_filter), do: true
  # Required for Ash to dispatch the atomic path under `authorize?: true` —
  # update.ex:71 gates `:update_query` behind this. Pure capability flag (no
  # callback — errors attach at the Ash.Changeset level, like ETS/Mnesia). Added
  # in the expr-cypher-translator arc (2.0.0).
  def can?(_, :expr_error), do: true
  # Bulk atomic update — one MATCH/WHERE/SET over the query-matched set. Ash
  # dispatches here for atomic updates when can?(:update_query) && can?(:expr_error)
  # (both required — update.ex:71/:235). Combined with :expr_error (above), this
  # is what makes `Ash.update(rec, atomics: [...])` and `Ash.bulk_update` reach
  # the translator instead of erroring/falling back. Added in 2.0.0.
  def can?(_, :update_query), do: true
  # update_many/3: distinct changes per record in one bulk call. Ash pre-groups
  # the batch by `{changeset.atomics, changeset.filter}` and dispatches each
  # group here (update_many.ex:130-178). We re-group defensively and synthesize
  # a per-group query carrying the group's filter + tenant discriminator + PK
  # scope, then delegate to the update_query machinery. Added in 2.0.0.
  def can?(_, :update_many), do: true
  # Atomic-update support gate (changeset.ex:5122 checks this BEFORE dispatch;
  # Ash.Error.Invalid.AtomicsNotSupported fires when false). The third capability
  # Ash requires for `Ash.update(rec, atomics: ...)` to reach update_query/4.
  def can?(_, {:atomic, :update}), do: true
  # {:atomic, :upsert} stays false: the two-statement existence-MATCH-then-SET
  # upsert path is non-atomic, so an `expr(count+1)` there would race. Ash
  # rejects upsert atomics at changeset validation; do_upsert/2's guard is the
  # defense-in-depth (D-rev8).
  def can?(_, _), do: false

  # === Required Callbacks ===

  @impl true
  def resource_to_query(resource, _domain) do
    graph = Info.graph(resource)
    label = Info.label(resource)
    repo = Info.repo(resource)

    %AshAge.Query{resource: resource, graph: graph, label: label, repo: repo}
  end

  @impl true
  def set_tenant(resource, %AshAge.Query{} = query, tenant) do
    # Fires only for :context (Ash guards `set_tenant` with the strategy). The
    # resolved name is validated by AshAge.Multitenancy.graph_name/2 and
    # re-validated at build time by Cypher.Parameterized (defense-in-depth).
    {:ok, %{query | graph: AshAge.Multitenancy.graph_name(resource, tenant)}}
  end

  @impl true
  def set_context(_resource, %AshAge.Query{} = query, context) do
    # Captures the tenant for RLS on reads. Ash sets context.private.tenant for ALL
    # strategies (Ash.Query.data_layer_query/2), including :attribute — where
    # set_tenant/3 never fires. Pure annotation; no query behavior changes unless
    # the resource declares rls_guc.
    #
    # This is the RAW query tenant (not the parse_attribute-coerced `to_tenant` the
    # write path uses); with_rls sets the GUC to `to_string(this)`. Those coincide
    # only within the supported tenant envelope — :string / uuid-as-string / integer,
    # where `Ash.ToTenant` and `parse_attribute` are identity (spec §3.2). A custom
    # `Ash.ToTenant`/`parse_attribute` would make the read GUC differ from the stored
    # property, so RLS would hide all rows — fail-closed (empty), never a leak.
    {:ok, %{query | tenant: get_in(context, [:private, :tenant])}}
  end

  @impl true
  def run_query(%AshAge.Query{} = query, resource) do
    Telemetry.span(:read, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, query.tenant, query.repo, fn -> run_query_body(query, resource) end)
        |> unwrap_rls(resource)

      {result,
       %{row_count: row_count(result), result: Telemetry.result_tag(result), rls?: rls?(resource)}}
    end)
  end

  defp run_query_body(%AshAge.Query{} = query, resource) do
    {cypher, params} = AshAge.Query.to_cypher(query)

    result =
      if map_size(params) > 0 do
        build_and_query(query.repo, query.graph, cypher, params)
      else
        # static build has no params — nothing to encode, no rescue needed
        {sql, pg_params} = Parameterized.build_static(query.graph, cypher)
        SQL.query(query.repo, sql, pg_params)
      end

    case result do
      {:ok, %{rows: rows}} ->
        attribute_map = Info.attribute_map(resource)
        attribute_types = Info.attribute_types(resource)

        records =
          Enum.map(rows, fn [agtype_text] ->
            vertex = Agtype.decode(agtype_text)

            attrs =
              Cast.vertex_to_resource_attrs(vertex, attribute_map, attribute_types)

            struct(resource, attrs)
          end)

        {:ok, records}

      # {:error, :params_not_json_encodable} needs no dedicated clause:
      # redact_db_error/1 names the encode failure with a value-free reason.
      {:error, error} ->
        {:error,
         QueryFailed.exception(
           query: "AGE read query",
           reason: redact_db_error(error)
         )}
    end
  end

  # === Aggregate Callbacks (Slice A) ===

  @impl true
  def add_aggregate(query, aggregate, _resource) do
    {:ok, %{query | aggregates: query.aggregates ++ [aggregate]}}
  end

  @impl true
  def add_aggregates(query, aggregates, resource) do
    # add_aggregate/3 always returns {:ok, _} (it appends and never fails), so the
    # reduce threads {:ok, query} straight through. (A `case … err -> {:halt, err}`
    # clause here would be unreachable — dialyzer pattern_match_cov.)
    Enum.reduce(aggregates, {:ok, query}, fn agg, {:ok, q} ->
      add_aggregate(q, agg, resource)
    end)
  end

  @impl true
  def run_aggregate_query(query, aggregates, resource) do
    Telemetry.span(:aggregate, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, query.tenant, query.repo, fn ->
          run_aggregate_query_body(query, aggregates, resource)
        end)
        |> unwrap_rls(resource)

      {result,
       %{
         aggregate_count: length(aggregates),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource)
       }}
    end)
  end

  defp run_aggregate_query_body(query, aggregates, resource) do
    # One Cypher per aggregate. AGE Cypher has no per-aggregate FILTER clause, so
    # aggregates with distinct sub-filters cannot share one MATCH...RETURN. Each
    # aggregate narrows independently; the cost is N round-trips for N aggregates
    # (rarely more than a few).
    Enum.reduce_while(aggregates, {:ok, %{}}, fn agg, {:ok, acc} ->
      case run_one_aggregate(query, agg, resource) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, agg.name, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp run_one_aggregate(query, agg, resource) do
    label = validated_label(resource)

    # S7 invariant: a binary-storage field is stored as `$age64$` base64, which is
    # NOT byte-order-preserving. min/max over it would return the
    # lexicographically-extreme base64 string (silently wrong + a type mismatch);
    # sum/avg are nonsensical on ciphertext. Reject as UnsupportedFilter — the
    # same guard `Filter.rangeable/2` applies to the filter path (filter.ex:214).
    with :ok <- aggregate_field_rangeable?(resource, agg) do
      {cypher, params} = AshAge.Query.aggregate_cypher(query, agg, label)

      case build_and_query(query.repo, query.graph, cypher, params, [{:agg, :agtype}]) do
        {:ok, %{rows: [[val_text]]}} ->
          {:ok, AshAge.Query.Aggregate.decode_value(agg.kind, Agtype.decode(val_text))}

        # count/exists over an empty set still return [[0]] in AGE; this guard is
        # for the should-not-happen no-row case. Return the kind's zero value.
        {:ok, %{rows: []}} ->
          {:ok, AshAge.Query.Aggregate.decode_value(agg.kind, 0)}

        {:error, error} ->
          {:error,
           QueryFailed.exception(query: "AGE aggregate query", reason: redact_db_error(error))}
      end
    end
  end

  # Only the field-bearing comparison/arithmetic aggregates can hit the binary
  # hole. count/exists take no field (they count vertices), so they are always OK.
  defp aggregate_field_rangeable?(_resource, %Ash.Query.Aggregate{kind: kind})
       when kind in [:count, :exists],
       do: :ok

  defp aggregate_field_rangeable?(resource, %Ash.Query.Aggregate{kind: kind, field: field})
       when kind in [:min, :max, :sum, :avg] do
    attr = Ash.Resource.Info.attribute(resource, field)
    type = if attr, do: attr.type, else: nil
    constraints = if attr && is_list(attr.constraints), do: attr.constraints, else: []

    if Cast.binary_storage?(type, constraints) do
      {:error, UnsupportedFilter.exception(operator: kind, field: field)}
    else
      :ok
    end
  end

  defp aggregate_field_rangeable?(_resource, _agg), do: :ok

  # === CRUD Callbacks ===

  @impl true
  def create(resource, changeset) do
    Telemetry.span(:create, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, Map.get(changeset, :to_tenant), Info.repo(resource), fn ->
          do_create(resource, changeset)
        end)
        |> unwrap_rls(resource)

      {result,
       %{tenant?: tenant?(changeset), result: Telemetry.result_tag(result), rls?: rls?(resource)}}
    end)
  end

  # do_create/2 is the current create/2 body, renamed verbatim (unchanged).
  defp do_create(resource, changeset) do
    case write_graph(resource, changeset) do
      {:ok, graph} ->
        repo = Info.repo(resource)
        label = validated_label(resource)

        props = changeset_to_properties(resource, changeset)

        case encode_check(props) do
          {:error, attr} ->
            {:error,
             CreateFailed.exception(resource: resource, reason: encode_error_reason(attr))}

          :ok ->
            create_vertex(resource, repo, label, graph, props)
        end

      {:error, :tenant_required} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: "multitenancy tenant required for :context write"
         )}
    end
  end

  # The single-create write proper (do_create's body after the graph resolution
  # and encode pre-check both pass), extracted verbatim.
  defp create_vertex(resource, repo, label, graph, props) do
    # AGE does NOT support CREATE (n:Label $props) — properties as a parameter
    # map in CREATE is not supported. Must use CREATE + SET pattern instead.
    set_clauses = set_clauses(props)

    cypher =
      if set_clauses == "" do
        "CREATE (n:#{label}) RETURN n"
      else
        "CREATE (n:#{label}) SET #{set_clauses} RETURN n"
      end

    case build_and_query(repo, graph, cypher, props) do
      {:ok, %{rows: [[vertex_text]]}} ->
        attribute_map = Info.attribute_map(resource)
        attribute_types = Info.attribute_types(resource)

        attrs =
          vertex_text
          |> Agtype.decode()
          |> Cast.vertex_to_resource_attrs(attribute_map, attribute_types)

        {:ok, struct(resource, attrs)}

      {:error, error} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: redact_db_error(error)
         )}
    end
  end

  @doc """
  Bulk-creates a batch of changesets via key-set-grouped `UNWIND ... CREATE`.

  A batch is fanned into one `SQL.query` per key-set group, so atomicity depends
  on Ash wrapping the batch in a transaction: on the default `transaction: :batch`
  path (this layer advertises `can?(:transact)`), a later-group failure rolls back
  earlier groups; under `transaction: false` the groups run unwrapped and a partial
  write is possible — the same contract single-create and AshPostgres carry.
  """
  @impl true
  def bulk_create(resource, changesets, opts) do
    # Ash passes a stream of %Ash.Changeset{} already carrying `.to_tenant` and a
    # `context.bulk_create.{index, ref}` stamp. Materialize preserving order, and
    # carry the changeset alongside its property map so returned records can be
    # tagged back to their originating changeset (Ash maps records to changesets
    # by `__metadata__.bulk_create_index`, NOT by positional order).
    entries = Enum.map(changesets, fn cs -> {cs, changeset_to_properties(resource, cs)} end)
    start = %{resource: resource, multitenancy: strategy(resource)}

    Telemetry.span(:bulk_create, start, fn ->
      # Encode pre-check gates the whole batch BEFORE any DB touch (inside the
      # span so the {result, metadata} contract is unchanged): a poisoned row
      # would otherwise raise Jason.EncodeError with the bytes in the message.
      result =
        case first_encode_failure(entries) do
          nil ->
            run_bulk_create(resource, entries, opts)

          attr ->
            {:error,
             CreateFailed.exception(resource: resource, reason: encode_error_reason(attr))}
        end

      {result,
       %{
         batch_size: length(entries),
         group_count: length(group_bulk_entries(entries)),
         tenant?: bulk_tenant?(entries),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource)
       }}
    end)
  end

  # An empty batch (e.g. a fully-filtered stream) writes nothing and touches no DB
  # — zero scoping surface — so it bypasses with_rls and returns the pre-S6 result
  # (`:ok`) rather than the blank-tenant fail-closed path. This is the ONLY
  # exception to the with_rls wrap-pin, justified by there being nothing to scope.
  defp run_bulk_create(resource, [] = entries, opts),
    do: bulk_create_body(resource, entries, opts)

  # Non-empty batch: identical with_rls wrap shape as the other four callbacks.
  defp run_bulk_create(resource, entries, opts) do
    with_rls(resource, bulk_tenant(entries), Info.repo(resource), fn ->
      bulk_create_body(resource, entries, opts)
    end)
    |> unwrap_rls(resource)
  end

  # The inner work of bulk_create/3 (named like run_query_body/do_create so the
  # with_rls wrap shape is identical to the other four callbacks). Resolves the
  # graph exactly as single-create does (via write_graph/2 through bulk_graph/2),
  # so the fail-closed nil-:context-tenant behavior is identical; Ash batches by
  # tenant, so every changeset in a batch shares one graph, resolved off the first.
  defp bulk_create_body(resource, entries, opts) do
    case bulk_graph(resource, entries) do
      {:ok, graph} ->
        do_bulk_create(resource, graph, entries, opts)

      {:error, :tenant_required} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: "multitenancy tenant required for :context write"
         )}
    end
  end

  defp bulk_tenant?([]), do: false
  defp bulk_tenant?([{changeset, _} | _]), do: tenant?(changeset)

  # The RLS GUC value for a NON-EMPTY bulk batch: Ash batches by tenant, so every
  # changeset shares one `to_tenant`; read it off the first. Only ever called on
  # the non-empty branch — bulk_create/3 short-circuits an empty batch past
  # with_rls entirely (nothing to scope) before this is ever reached.
  defp bulk_tenant([{changeset, _} | _]), do: Map.get(changeset, :to_tenant)

  @impl true
  def update(resource, changeset) do
    Telemetry.span(:update, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, Map.get(changeset, :to_tenant), Info.repo(resource), fn ->
          do_update(resource, changeset)
        end)
        |> unwrap_rls(resource)

      {result,
       %{
         tenant?: tenant?(changeset),
         stale?: stale?(result),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource)
       }}
    end)
  end

  defp do_update(resource, changeset) do
    case write_graph(resource, changeset) do
      {:ok, graph} ->
        repo = Info.repo(resource)
        label = validated_label(resource)

        changed_attrs = changeset_to_properties(resource, changeset)

        case encode_check(changed_attrs) do
          {:error, attr} ->
            {:error,
             UpdateFailed.exception(resource: resource, reason: encode_error_reason(attr))}

          :ok ->
            update_vertex(resource, changeset, repo, label, graph, changed_attrs)
        end

      {:error, :tenant_required} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: "multitenancy tenant required for :context write"
         )}
    end
  end

  # The single-update write proper (do_update's body after the graph resolution
  # and encode pre-check both pass), extracted verbatim.
  defp update_vertex(resource, changeset, repo, label, graph, changed_attrs) do
    plain_set = set_clauses(changed_attrs)

    # Match on the resource's full primary key (composite or non-:id supported).
    # `changed_attrs` are reserved so a match param never clobbers a SET param.
    pk = pk_pairs(resource, changeset)
    {where_clause, match_params} = pk_match_clause(pk, changed_attrs)

    case changeset_where(changeset, where_clause, Map.merge(changed_attrs, match_params)) do
      {:ok, full_where, params} ->
        # Translate `changeset.atomics` (a keyword list of {attr, expr}) via the
        # Cypher translator, threading the in-flight param names as `taken` so
        # positional atomic params cannot collide with plain-attr params. Atomics
        # emit AFTER plain attributes: Cypher SET is last-wins, so for a same-attr
        # plain+atomic conflict the atomic wins (mirrors Ash's intent). An
        # untranslatable expr fails CLOSED as UpdateFailed — never a silent drop
        # (the S7 silent-drop class this arc closes).
        case atomic_set_clauses(resource, changeset, Map.keys(params)) do
          {:ok, [], atomic_params} ->
            emit_update_cypher(
              resource,
              repo,
              graph,
              label,
              pk,
              full_where,
              plain_set,
              Map.merge(params, atomic_params)
            )

          {:ok, atomic_clauses, atomic_params} ->
            set_str = combine_set_clauses(plain_set, atomic_clauses)

            emit_update_cypher(
              resource,
              repo,
              graph,
              label,
              pk,
              full_where,
              set_str,
              Map.merge(params, atomic_params)
            )

          {:error, _} ->
            {:error,
             UpdateFailed.exception(
               resource: resource,
               reason: "unsupported atomic expression on update"
             )}
        end

      {:error, _} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: "unsupported scoping filter on update"
         )}
    end
  end

  defp emit_update_cypher(resource, repo, graph, label, pk, full_where, set_str, params) do
    cypher = """
    MATCH (n:#{label})
    WHERE #{full_where}
    SET #{set_str}
    RETURN n
    """

    decode_update_result(
      resource,
      redacted_filter(pk),
      build_and_query(repo, graph, cypher, params)
    )
  end

  # Translate `changeset.atomics` (keyword list of {attr, expr}) into SET
  # clauses via AshAge.Cypher.Expr, threading `taken` (the param names already
  # in flight) so positional atomic params allocate collision-free names.
  # Returns `{:ok, clauses_list, params_map}` (clauses_list empty when no
  # atomics) or `{:error, UnsupportedExpression}` (fail-closed).
  defp atomic_set_clauses(_resource, %{atomics: []}, _taken), do: {:ok, [], %{}}

  defp atomic_set_clauses(_resource, changeset, taken) do
    initial = %{taken: MapSet.new(taken), count: 0, params: %{}}

    result =
      Enum.reduce_while(changeset.atomics, {:ok, [], initial}, fn {attr, value},
                                                                  {:ok, clauses, acc} ->
        with {:ok, expr} <- atomic_expr(value),
             {:ok, frag, expr_params} <-
               Expr.translate(expr, %{taken: acc.taken, count: acc.count}) do
          attr_str = attr |> to_string() |> tap(&AshAge.Migration.validate_identifier!/1)
          clause = "n.`#{attr_str}` = #{frag}"
          new_taken = Enum.reduce(Map.keys(expr_params), acc.taken, &MapSet.put(&2, &1))

          {:cont,
           {:ok, clauses ++ [clause],
            %{
              acc
              | taken: new_taken,
                count: acc.count + map_size(expr_params),
                params: Map.merge(acc.params, expr_params)
            }}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, clauses, acc} -> {:ok, clauses, acc.params}
      err -> err
    end
  end

  # The atomic value is normally the expr AST directly (`atomic_update(:x, expr(...))`
  # stores the expr in the keyword list). The processed `{:atomic, _, _, expr}`
  # tuple form appears only on the fully-atomic bulk path (Task 4); extract its
  # expr. Anything else is rejected fail-closed by the translator's catch-all.
  defp atomic_expr({:atomic, _fields, _condition, expr}), do: {:ok, expr}
  defp atomic_expr(expr), do: {:ok, expr}

  # Combine plain-attr SET clauses with atomic SET clauses. Plain may be empty
  # (atomic-only update); atomics list is non-empty at the call site.
  defp combine_set_clauses("", atomic_clauses), do: Enum.join(atomic_clauses, ", ")

  defp combine_set_clauses(plain, atomic_clauses),
    do: plain <> ", " <> Enum.join(atomic_clauses, ", ")

  @impl true
  def destroy(resource, changeset) do
    Telemetry.span(:destroy, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, Map.get(changeset, :to_tenant), Info.repo(resource), fn ->
          do_destroy(resource, changeset)
        end)
        |> unwrap_rls(resource)

      {result,
       %{
         tenant?: tenant?(changeset),
         stale?: stale?(result),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource)
       }}
    end)
  end

  defp do_destroy(resource, changeset) do
    case write_graph(resource, changeset) do
      {:ok, graph} ->
        repo = Info.repo(resource)
        label = validated_label(resource)

        pk = pk_pairs(resource, changeset)
        {where_clause, match_params} = pk_match_clause(pk, %{})

        case changeset_where(changeset, where_clause, match_params) do
          {:ok, full_where, params} ->
            # `RETURN n` makes AGE echo each deleted vertex so we can distinguish a
            # real deletion from a no-match. Without it, `DETACH DELETE n` returns
            # zero rows whether or not anything matched — which would silently
            # report success for a scoping-denied (cross-tenant) delete. An empty
            # result therefore fails CLOSED as StaleRecord, mirroring update/2.
            cypher = """
            MATCH (n:#{label})
            WHERE #{full_where}
            DETACH DELETE n
            RETURN n
            """

            decode_destroy_result(
              resource,
              redacted_filter(pk),
              build_and_query(repo, graph, cypher, params, [{:n, :agtype}])
            )

          {:error, _} ->
            {:error,
             QueryFailed.exception(
               query: "AGE delete query",
               reason: "unsupported scoping filter on destroy"
             )}
        end

      {:error, :tenant_required} ->
        {:error,
         QueryFailed.exception(
           query: "AGE delete query",
           reason: "multitenancy tenant required for :context write"
         )}
    end
  end

  # === Upsert (Slice B) ===
  #
  # Two-statement, NON-MERGE path (AGENTS.md rule 2: AGE MERGE has catastrophic
  # perf bugs). Inside the existing transaction (`:transact`): an existence MATCH
  # (identity AND tenant predicate) → CREATE branch if absent/cross-tenant-excluded,
  # SET branch if present (same tenant). Not atomic across concurrent upserts of
  # the same identity (both see c==0, both create → duplicate); AGE enforces no PK
  # uniqueness, so this is the inherent AGE contract — documented, same shape as
  # the existing "no idempotent create" reality. A host needing race protection
  # must enforce uniqueness outside AGE (a UNIQUE index over the agtype property is
  # unprobed on this build).

  @impl true
  def upsert(resource, changeset, identity_fields, _identity) do
    Telemetry.span(:upsert, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, Map.get(changeset, :to_tenant), Info.repo(resource), fn ->
          do_upsert(resource, changeset, identity_fields)
        end)
        |> unwrap_rls(resource)

      {result,
       %{
         tenant?: tenant?(changeset),
         stale?: stale?(result),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource)
       }}
    end)
  end

  defp do_upsert(resource, changeset, identity_fields) do
    # Upsert REJECTS atomics: the two-statement existence-MATCH-then-SET path is
    # non-atomic (AGE enforces no PK uniqueness + the no-MERGE rule), so an
    # `expr(count + 1)` there would read-modify-write against a value that can
    # change between the existence count and the SET — a silent stale write.
    # Fail closed with a value-free error rather than race or silently drop
    # (the S7 silent-drop class). Owned by a follow-up if a host genuinely needs
    # atomic upsert increments (would require a UNIQUE index on the identity,
    # unprobed on this AGE build).
    if changeset.atomics != [] do
      {:error,
       CreateFailed.exception(
         resource: resource,
         reason: "atomics are not supported on upsert (non-atomic two-statement path)"
       )}
    else
      upsert_do(resource, changeset, identity_fields)
    end
  end

  defp upsert_do(resource, changeset, identity_fields) do
    case write_graph(resource, changeset) do
      {:ok, graph} ->
        repo = Info.repo(resource)
        label = validated_label(resource)
        props = changeset_to_properties(resource, changeset)

        case encode_check(props) do
          {:error, attr} ->
            {:error,
             CreateFailed.exception(resource: resource, reason: encode_error_reason(attr))}

          :ok ->
            upsert_vertex(resource, changeset, repo, label, graph, props, identity_fields)
        end

      {:error, :tenant_required} ->
        {:error,
         CreateFailed.exception(
           resource: resource,
           reason: "multitenancy tenant required for :context write"
         )}
    end
  end

  defp upsert_vertex(resource, changeset, repo, label, graph, props, identity_fields) do
    # `identity_fields` (built by Ash at create.ex:298-313) already carries the
    # cross-tenant scoping where it belongs: for `:attribute` multitenancy Ash
    # PREPENDS the multitenancy attribute to a per-tenant identity
    # (`Enum.uniq([mt_attr | keys])`); for `all_tenants?: true` identities it
    # intentionally excludes it (global upsert); for PK-based upsert it passes the
    # primary key. So identity_pairs is the COMPLETE, correct match — no separate
    # tenant predicate is needed (and adding one would WRONGLY scope `all_tenants?`
    # identities, breaking global upsert). Verified: the C2 design-adversarial
    # concern (changeset.filter is nil on the create path) is resolved by Ash's
    # identity construction, not by a layer-level predicate.
    identity_pairs = identity_pairs(resource, changeset, identity_fields)

    case upsert_existence(repo, label, graph, identity_pairs) do
      {:ok, count} when count > 0 ->
        # Present (same tenant — identity_fields excluded cross-tenant rows).
        upsert_update_branch(resource, repo, label, graph, props, identity_pairs)

      {:ok, 0} ->
        # Absent OR cross-tenant-excluded → CREATE (Ash force-set the tenant attr
        # for :attribute; :context resolved the tenant's graph via write_graph).
        create_vertex(resource, repo, label, graph, props)

      {:error, _} = error ->
        error
    end
  end

  # F1: identity match values come from `Ash.Changeset.get_attribute/2` — the
  # PENDING new value — NOT `get_data/2` (which reads `changeset.data`, an empty
  # struct on the create-path → nil → always-CREATE). Each value is serialized by
  # the attribute's type+constraints so the match carries the stored wire form.
  defp identity_pairs(resource, changeset, identity_fields) do
    Enum.map(identity_fields, fn field ->
      attr = Ash.Resource.Info.attribute(resource, field)
      type = if attr, do: attr.type, else: nil
      constraints = if attr && is_list(attr.constraints), do: attr.constraints, else: []
      value = Ash.Changeset.get_attribute(changeset, field)
      {field, Cast.serialize_value(value, {type, constraints})}
    end)
  end

  defp upsert_match_clause(identity_pairs) do
    pk_match_clause(identity_pairs, %{})
  end

  # Existence check: MATCH by identity_fields, count, LIMIT 1. identity_fields is
  # the barrier (tenant-scoped for per-tenant identities via Ash's mt-attr
  # prepend); with_rls adds defense-in-depth read-confidentiality around it.
  defp upsert_existence(repo, label, graph, identity_pairs) do
    {where, match_params} = upsert_match_clause(identity_pairs)
    cypher = "MATCH (n:#{label}) WHERE #{where} RETURN count(n) AS c LIMIT 1"

    case build_and_query(repo, graph, cypher, match_params, [{:c, :agtype}]) do
      {:ok, %{rows: [[count_text]]}} -> {:ok, Agtype.decode(count_text)}
      {:ok, %{rows: []}} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  # Update branch: MATCH by identity_fields, SET the non-PK attrs, RETURN n.
  # identity_fields carries the same tenant scoping as the existence check, so the
  # SET is bounded to the caller's tenant (a cross-tenant duplicate sharing the
  # identity is excluded by identity_fields' mt-attr). decode_update_result
  # handles 1-row / multi-row / empty (multi-row = within-tenant duplicates, an
  # error since AGE allows them outside Ash).
  defp upsert_update_branch(resource, repo, label, graph, props, identity_pairs) do
    # Exclude the primary key from the SET: Ash generates a fresh PK per changeset,
    # so SETting it would overwrite the matched row's identity (a uuid PK would be
    # rewritten to the new changeset's id, desyncing Ash's reference to the row).
    # AshPostgres upsert semantics: conflict on the identity, PK unchanged.
    pk_fields = resource |> Ash.Resource.Info.primary_key() |> MapSet.new()

    update_props =
      Map.reject(props, fn {key, _} ->
        MapSet.member?(pk_fields, String.to_existing_atom(key))
      end)

    set_clause = set_clauses(update_props)
    {where, match_params} = upsert_match_clause(identity_pairs)
    params = Map.merge(props, match_params)

    cypher =
      if set_clause == "" do
        # No non-PK attrs to update — a no-op MATCH...RETURN (the existence check
        # already proved the row exists).
        "MATCH (n:#{label}) WHERE #{where} RETURN n"
      else
        "MATCH (n:#{label}) WHERE #{where} SET #{set_clause} RETURN n"
      end

    decode_update_result(
      resource,
      redacted_filter(identity_pairs),
      build_and_query(repo, graph, cypher, params)
    )
  end

  # === destroy_query (Slice C) ===
  #
  # Bulk destroy by query: one `MATCH ... WHERE <translated filter> DETACH DELETE n`
  # over the full filtered set (Ash's `:destroy_query` gate). The WHERE is the SAME
  # translated filter the read path uses (`build_where`), so destroy_query deletes
  # EXACTLY the rows a read would return — including the tenant predicate Ash
  # attaches to the bulk-action query for :attribute multitenancy (verified at
  # Ash `destroy/bulk.ex:714` -> `read.ex:2749 handle_attribute_multitenancy`).
  # Ash rejects unsupported filter operators at `Ash.Query` build via
  # `can?({:filter_expr, _})`, so an untranslatable filter cannot reach this path
  # (the catastrophic unscoped-delete case is gated upstream). `return_records?`
  # uses read-then-delete: Cypher cannot RETURN deleted nodes.

  @impl true
  def destroy_query(query, changeset, resource, opts) do
    # `changeset` is the destroy-action template (no attribute changes for a plain
    # destroy); it is unused here. Ash attaches before/after-action hooks to it
    # out-of-band — when a destroy action carries hooks, Ash falls back to
    # per-record `destroy/2` (already safe) instead of calling destroy_query.
    _ = changeset

    Telemetry.span(:destroy, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, query.tenant, query.repo, fn ->
          destroy_query_body(query, resource, opts)
        end)
        |> unwrap_rls(resource)

      {result,
       %{
         tenant?: not is_nil(query.tenant),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource)
       }}
    end)
  end

  defp destroy_query_body(query, resource, opts) do
    label = validated_label(resource)
    return_records? = Map.get(opts, :return_records?, false)

    if return_records? do
      # Cypher can't RETURN deleted nodes — materialize the matched records first
      # (via the read path), then DELETE. The two statements run inside with_rls's
      # transaction (when RLS is on) so the read and delete see the same scoped view.
      with {:ok, records} <- run_query_body(query, resource),
           :ok <- destroy_query_delete(query, label) do
        {:ok, records}
      end
    else
      destroy_query_delete(query, label)
    end
  end

  defp destroy_query_delete(query, label) do
    {cypher, params} = AshAge.Query.delete_cypher(query, label)

    case build_and_query(query.repo, query.graph, cypher, params) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        {:error,
         QueryFailed.exception(query: "AGE destroy_query", reason: redact_db_error(error))}
    end
  end

  # === update_query/4 (bulk atomic update — expr-cypher-translator arc, 2.0.0) ===
  #
  # Applies ONE changeset (plain attributes + translated atomics) to every record
  # the query matches, in a single MATCH/WHERE/SET/RETURN. Ash dispatches here for
  # atomic updates when can?(:update_query) && can?(:expr_error). Scoping source is
  # `build_where(query)` (query.expression) — the :attribute tenant predicate arrives
  # there via Ash's handle_attribute_multitenancy, NOT changeset.filter (which Ash
  # nils before the DL runs — adversarial Challenge 1). On a 0-row match returns
  # `:ok` (the bulk contract, Challenge 7) — NOT StaleRecord.

  @impl true
  def update_query(query, changeset, resource, opts) do
    Telemetry.span(:update_query, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      result =
        with_rls(resource, query.tenant, query.repo, fn ->
          update_query_body(query, changeset, resource, opts)
        end)
        |> unwrap_rls(resource)

      {result,
       %{
         tenant?: not is_nil(query.tenant),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource),
         atomic?: changeset.atomics != []
       }}
    end)
  end

  @impl true
  def update_many(resource, changesets, opts) do
    Telemetry.span(:update_many, %{resource: resource, multitenancy: strategy(resource)}, fn ->
      tenant = opts[:tenant]

      result =
        with_rls(resource, tenant, Info.repo(resource), fn ->
          update_many_body(resource, changesets, opts, tenant)
        end)
        |> unwrap_rls(resource)

      # `atomic?` is true when ANY changeset in the batch carried an expr-based
      # atomic (vs plain attribute sets). Value-free: a boolean over the change
      # shape, not a row value.
      batch_atomic? = Enum.any?(changesets, fn cs -> cs.atomics != [] end)

      {result,
       %{
         tenant?: not is_nil(tenant),
         result: Telemetry.result_tag(result),
         rls?: rls?(resource),
         atomic?: batch_atomic?
       }}
    end)
  end

  # update_many receives NO query (the contract is `{resource, changesets, opts}`) —
  # each group synthesizes its own AshAge.Query carrying the group's shared Ash
  # filter, the `:attribute` tenant discriminator (built from opts[:tenant], which
  # lives in bulk_update_options NOT on each changeset — Challenge 2), and a
  # PK-restriction bounding the SET to exactly this group's records. Then it
  # delegates to update_query_body (the same machinery bulk_update uses).
  defp update_many_body(resource, changesets, opts, tenant) do
    label = validated_label(resource)

    # Fail closed on a blank tenant for a multitenant resource that REQUIRES one.
    # :context is caught by update_many_graph below; :attribute is caught HERE —
    # applying the parse fn to nil would scope the SET to a phantom tenant
    # (wrong-empty, not an error), and a missing discriminator would be a silent
    # cross-tenant write (the recurring class). A `global? true` :attribute
    # resource legitimately allows a nil tenant (cross-vendor closeout finding:
    # the prior guard over-rejected it), so consult multitenancy_global?/1.
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute and
         not Ash.Resource.Info.multitenancy_global?(resource) and
         tenant in [nil, ""] do
      {:error,
       UpdateFailed.exception(resource: resource, reason: "tenant required for update_many")}
    else
      update_many_grouped(resource, changesets, opts, tenant, label)
    end
  end

  defp update_many_grouped(resource, changesets, opts, tenant, label) do
    case update_many_graph(resource, tenant) do
      {:ok, graph} ->
        # Re-group defensively. Ash pre-groups by `{atomics, filter}`, but static
        # attribute values live in `changeset.attributes` (NOT `atomics`) — so two
        # inputs `{rec, %{count: 10}}` and `{rec, %{count: 20}}` share the same
        # atomics (empty) and would collapse into one group, letting the
        # representative's `%{count: 10}` SET apply to both. Including `attributes`
        # in the key splits them into uniform-SET sub-groups, each correct. The
        # atomics term is the shared EXPR (e.g. count+1) — grouped by structural
        # identity, so identical exprs still batch.
        groups =
          Enum.group_by(changesets, fn cs -> {cs.atomics, cs.filter, cs.attributes} end)

        run_update_many_groups(groups, resource, graph, label, tenant, opts)

      {:error, :tenant_required} ->
        # :context multitenancy with a nil/blank tenant: there is no global graph
        # to fall back to — fail CLOSED (no silent cross-tenant write).
        {:error,
         UpdateFailed.exception(resource: resource, reason: "tenant required for update_many")}
    end
  end

  defp run_update_many_groups(groups, resource, graph, label, tenant, opts) do
    Enum.reduce_while(groups, {:ok, []}, fn {_group_key, group_changesets}, {:ok, acc_records} ->
      case update_many_group(resource, graph, label, tenant, hd(group_changesets), group_changesets, opts) do
        # `:ok` arises from run_update_query whenever `return_records?` is false
        # (Ash does not request records for this batch) — continue with no records.
        :ok -> {:cont, {:ok, acc_records}}
        {:ok, records} -> {:cont, {:ok, acc_records ++ records}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp update_many_group(resource, graph, label, tenant, representative, group_changesets, opts) do
    query = %AshAge.Query{
      resource: resource,
      graph: graph,
      label: label,
      repo: Info.repo(resource),
      tenant: tenant
    }

    # Reserve every attribute name before any scoping param allocation so a
    # PK/tenant/filter `$paramN` can never share a name with a SET attr (the
    # `param<N>`-collision class). Same discipline as `filter/3` on the
    # update_query path; covers update_many's synthesized query.
    query = reserve_attr_params(query, resource)

    # Translate the group's shared changeset.filter EAGERLY and fail CLOSED on an
    # untranslatable operator. Putting the filter into `query.expression` instead
    # (as a prior revision did) lets `build_where` swallow translation errors
    # (`_ -> {[], query}`, lib/query.ex), so a changeset.filter using an
    # unsupported operator (optimistic-lock, a ref-to-ref policy filter, a
    # fragment) would be silently dropped and the SET would fall back to PK +
    # tenant scope — updating rows the filter was meant to exclude (cross-vendor
    # closeout finding B2; violates the `can?(:changeset_filter)` fail-closed
    # contract). Pre-translating here makes the error loud before any write.
    #
    # NOTE: a no-op group (no atomics AND no effective attrs — `age skip` attrs
    # don't count) is handled below `case query do` by running a scoped READ and
    # returning the matched records unchanged (read_update_many_matches). That is
    # the honest path between a bare `:ok` (Ash reads as all-stale) and an early
    # return of the inputs (which bypassed changeset.filter — cross-vendor
    # delta-2 finding, reverted). The filter is translated above (fail-closed on
    # an untranslatable operator); the read gates the result on it.
    query = scope_to_filter(query, representative.filter)

    case query do
      {:error, _} = e ->
        e

      query ->
        # Scope the SET to (a) the tenant discriminator for :attribute resources
        # and (b) exactly this group's PKs — so a synthesized query can never
        # widen past the group Ash handed us.
        query = scope_to_tenant(query, resource, tenant)
        query = scope_to_group_pks(query, resource, group_changesets)

        if no_op_changeset?(resource, representative) do
          # A no-op group (no atomics AND no plain attrs): run a READ with the
          # filter + tenant + PK scope and return the matched records UNCHANGED.
          # The filter gates the result (a filter-carrying no-op — optimistic
          # lock, policy filter — excludes denied rows, which Ash then classifies
          # stale, correctly); matching records are returned so Ash does not mark
          # them stale. This is the honest path between a bare `:ok` (Ash reads
          # as all-stale) and an early return of the inputs (which bypassed the
          # filter — cross-vendor delta-2 finding). No SET, no write.
          read_update_many_matches(query, resource)
        else
          # Delegate to the bulk-update machinery. representative carries the
          # group's shared atomics + plain attrs; update_query_body translates both.
          update_query_body(query, representative, resource, opts)
        end
    end
  end

  # A no-op group: no atomics AND no EFFECTIVE plain attrs. Keyed on the
  # EFFECTIVE changed attrs (changeset_to_properties, which rejects `age skip`
  # attrs), NOT raw `changeset.attributes` — a changeset modifying only skip-
  # listed attrs has non-empty `attributes` but empty `changed_attrs`, and must
  # still take the no-op read path or Ash marks the existing rows stale
  # (cross-vendor delta-4 finding).
  defp no_op_changeset?(resource, changeset) do
    changeset.atomics == [] and map_size(changeset_to_properties(resource, changeset)) == 0
  end

  # The no-op read: `MATCH (n:L) WHERE <filter + tenant + PK> RETURN n`, decode,
  # fail-closed on a duplicate-PK anomaly (AGE enforces no uniqueness — one input
  # PK matching 2+ rows is an integrity violation). No SET, no write — only
  # verifies which inputs match (filter + existence) so Ash can classify them
  # (matching → success-unchanged, excluded/missing → stale).
  defp read_update_many_matches(query, resource) do
    {cypher, params} = AshAge.Query.to_cypher(query)

    case build_and_query(query.repo, query.graph, cypher, params, [{:n, :agtype}]) do
      {:ok, %{rows: rows}} ->
        fail_closed_on_duplicate_pk(resource, decode_records(resource, rows))

      {:error, error} ->
        {:error, QueryFailed.exception(query: "AGE update_many no-op read", reason: redact_db_error(error))}
    end
  end

  # Fail CLOSED on a duplicate-PK-in-graph anomaly: AGE enforces no PK
  # uniqueness, so a bulk update/read by PK can match 2+ physical rows for one
  # input PK. Deduping the RETURNED records would hide that the SET already wrote
  # every match (silent multi-row corruption for one logical update) — so detect
  # the cardinality violation and fail closed (the surrounding transaction rolls
  # the write back). Consistent with the single-record reroute's guard. Returns
  # `{:ok, records}` when every PK is distinct, `{:error, UpdateFailed}` otherwise.
  defp fail_closed_on_duplicate_pk(resource, records) do
    pk_fields = Ash.Resource.Info.primary_key(resource)
    counts = Enum.frequencies_by(records, &Map.take(&1, pk_fields))

    case Enum.find(counts, fn {_pk, n} -> n > 1 end) do
      nil ->
        {:ok, records}

      {_pk, n} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason:
             "update_many matched #{n} rows for one primary key (duplicate rows in graph?)"
         )}
    end
  end

  # Single-record duplicate-PK error (Ash's per-record wrapper requires exactly 1).
  defp duplicate_pk_error(resource, n) do
    {:error,
     UpdateFailed.exception(
       resource: resource,
       reason: "update matched #{n} rows for one primary key (duplicate rows in graph?)"
     )}
  end

  # Bulk-path result: fail-closed on duplicate-PK, else return records (or :ok).
  defp bulk_update_result(resource, decoded, return_records?) do
    case fail_closed_on_duplicate_pk(resource, decoded) do
      {:ok, decoded} when return_records? -> {:ok, decoded}
      {:ok, _} -> :ok
      {:error, _} = e -> e
    end
  end

  # Fail-closed translation of the group's changeset.filter into a pre-built
  # WHERE clause on `query.filters` (NOT `query.expression`, whose translation
  # `build_where` swallows). Threaded params land in `query.params`. `nil` and
  # `%Ash.Filter{expression: nil}` mean "no filter" — no clause added.
  defp scope_to_filter(query, nil), do: query

  defp scope_to_filter(query, %Ash.Filter{expression: nil}), do: query

  defp scope_to_filter(query, %Ash.Filter{} = filter) do
    case Filter.translate(filter, query) do
      {:ok, query, ""} ->
        query

      {:ok, query, clause} ->
        %{query | filters: query.filters ++ [clause]}

      {:error, _} = e ->
        e
    end
  end

  # :context → per-tenant graph (fail-closed on blank tenant). :attribute / none
  # → the resource's base graphs (the tenant discriminator is a WHERE predicate,
  # not a graph choice).
  defp update_many_graph(resource, tenant) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :context do
      case tenant do
        blank when blank in [nil, ""] -> {:error, :tenant_required}
        t -> {:ok, AshAge.Multitenancy.graph_name(resource, t)}
      end
    else
      {:ok, Info.graph(resource)}
    end
  end

  # Adds the `:attribute` tenant discriminator to the WHERE (n.`attr` = $tenant).
  # For :attribute resources, Ash's handle_attribute_multitenancy normally adds
  # this BEFORE the data layer — but update_many bypasses that step (no query
  # goes through Ash's read path), so we build it here from opts[:tenant]. The
  # value is run through the resource's multitenancy_parse_attribute, matching
  # Ash's own handling (read.ex:2749-2755). No-op for :context (graph isolation)
  # and for non-multitenant resources.
  defp scope_to_tenant(query, resource, tenant) do
    strategy = Ash.Resource.Info.multitenancy_strategy(resource)

    # Gate on TENANT PRESENCE (non-nil), not on `global?` and not on `""`. Ash's
    # `handle_attribute_multitenancy` (read.ex:2749-2756) adds the discriminator
    # whenever `query.tenant` is set; Ash preserves a `""` tenant bitstring
    # (to_tenant.ex:34), so `""` is a provided tenant that MUST scope (to its
    # value), not a blank to skip. Gating on `tenant not in [nil, ""]` (a prior
    # revision) treated `""` as blank, so a global resource with `tenant=""` got
    # no discriminator and the PK scope alone could match a duplicate-PK row in
    # another tenant (cross-vendor delta-3 finding). `nil` is the only "no tenant".
    if strategy == :attribute and tenant != nil do
      attr = Ash.Resource.Info.multitenancy_attribute(resource)

      if attr do
        {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(resource)
        parsed = apply(m, f, [tenant | a])
        {query, param} = AshAge.Query.add_param(query, parsed)
        key = attr |> to_string() |> AshAge.Migration.validate_identifier!()
        %{query | filters: query.filters ++ ["n.`#{key}` = #{param}"]}
      else
        query
      end
    else
      query
    end
  end

  # Bounds the SET to exactly this group's PKs.
  # Single-attr PK → `n.`pk` IN $pks` (one list param, AGE binds JSON list).
  # Composite PK → OR-disjunction of per-record AND-conjunctions (AGE has no
  # row-valued IN). PK values are serialized by attribute type so equality matches
  # the stored wire form (binary-tagged, date-ISO — same as the filter path).
  defp scope_to_group_pks(query, resource, group_changesets) do
    pk_fields = Ash.Resource.Info.primary_key(resource)
    types = Info.attribute_types(resource)

    if length(pk_fields) == 1 do
      [pk] = pk_fields
      type = Map.get(types, pk)
      values = Enum.map(group_changesets, &Cast.serialize_value(pk_value(&1, pk), type))
      {query, param} = AshAge.Query.add_param(query, values)
      key = pk |> to_string() |> AshAge.Migration.validate_identifier!()
      %{query | filters: query.filters ++ ["n.`#{key}` IN #{param}"]}
    else
      {disjuncts, query} =
        Enum.map_reduce(group_changesets, query, &composite_pk_conjuncts(&1, &2, pk_fields, types))

      %{query | filters: query.filters ++ ["(" <> Enum.join(disjuncts, " OR ") <> ")"]}
    end
  end

  # One record's composite-PK match as an AND-conjunction, threading param
  # allocation. `(n.`k1` = $p1 AND n.`k2` = $p2)`. Extracted from
  # scope_to_group_pks to keep nesting under credo's max.
  defp composite_pk_conjuncts(changeset, query, pk_fields, types) do
    {conjuncts, query} =
      Enum.map_reduce(pk_fields, query, fn field, q2 ->
        type = Map.get(types, field)
        {q2, param} = AshAge.Query.add_param(q2, Cast.serialize_value(pk_value(changeset, field), type))
        key = field |> to_string() |> AshAge.Migration.validate_identifier!()
        {"n.`#{key}` = #{param}", q2}
      end)

    {"(" <> Enum.join(conjuncts, " AND ") <> ")", query}
  end

  defp pk_value(changeset, field), do: Ash.Changeset.get_data(changeset, field)

  defp update_query_body(query, changeset, resource, opts) do
    label = validated_label(resource)
    return_records? = Map.get(opts, :return_records?, false)
    # Ash reroutes a single-record `Ash.update/2` through update_query when
    # :update_query+:expr_error are advertised (update.ex:190-231). That reroute
    # sets `context[:data_layer][:use_atomic_update_data?]` and keeps the real
    # record in `changeset.data` (the true bulk path sends OriginalDataNotAvailable
    # + no such flag). The single-record contract (update.ex:210) pattern-matches
    # `records: [record]` — exactly one — so a multi-row match must fail CLOSED
    # here (a duplicate PK in the graph, which AGE does not enforce), not return
    # 2+ records and crash Ash's wrapper.
    single_record? = single_record_reroute?(changeset)

    changed_attrs = changeset_to_properties(resource, changeset)
    plain_set = set_clauses(changed_attrs)

    # Translate atomics, threading the in-flight param names (plain attrs + the
    # WHERE params from build_where) so positional atomic params can't collide.
    taken = Map.keys(changed_attrs) ++ Map.keys(query.params)

    case atomic_set_clauses(resource, changeset, taken) do
      {:ok, [], atomic_params} ->
        # No-op when there are no plain attrs either: no atomics AND no changed
        # attrs → a bare `SET ` is invalid Cypher, so short-circuit with no DB
        # touch. For a single-record reroute, return the unchanged record (Ash
        # expects `records: [record]`); for a true bulk no-op, `:ok`.
        if map_size(changed_attrs) == 0 do
          noop_result(single_record?, changeset, return_records?)
        else
          run_update_query(
            query,
            label,
            plain_set,
            changed_attrs,
            atomic_params,
            resource,
            return_records?,
            single_record?
          )
        end

      {:ok, atomic_clauses, atomic_params} ->
        set_str = combine_set_clauses(plain_set, atomic_clauses)

        run_update_query(
          query,
          label,
          set_str,
          changed_attrs,
          atomic_params,
          resource,
          return_records?,
          single_record?
        )

      {:error, _} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: "unsupported atomic expression in bulk update"
         )}
    end
  end

  # Ash's single-record update reroute: `use_atomic_update_data?` is set in the
  # data-layer context AND `changeset.data` is the real record (not the
  # OriginalDataNotAvailable sentinel the true bulk path sends). Either signal
  # identifies the reroute; require the flag (the documented marker).
  defp single_record_reroute?(changeset) do
    changeset.context[:data_layer][:use_atomic_update_data?] == true
  end

  defp noop_result(true = _single_record?, changeset, _return_records?) do
    {:ok, [changeset.data]}
  end

  defp noop_result(false = _single_record?, _changeset, _return_records?) do
    :ok
  end

  defp run_update_query(
         query,
         label,
         set_str,
         changed_attrs,
         atomic_params,
         resource,
         return_records?,
         single_record?
       ) do
    pk_fields = Ash.Resource.Info.primary_key(resource)

    # Pre-write duplicate-PK check: AGE enforces no PK uniqueness, so a bulk SET
    # could write multiple physical rows for one input PK. Detecting it BEFORE the
    # SET (keyed on SOURCE PKs) means the failure is clean under any transaction
    # mode, and a SET that rewrites the PK can't evade it. One grouped-count query.
    #
    # The check and SET are separate statements. Under READ COMMITTED (Ash's
    # default) a concurrent same-PK INSERT between them is a TOCTOU window; and a
    # LIMIT-without-ORDER-BY update has a non-deterministic slice (the check and
    # SET could pick different rows). AGE provides no PK constraints (Postgres/ETS
    # enforce these at the DB), so ash_age cannot make check+set atomic. The
    # post-write defense-in-depth below + the action transaction catch the common
    # case; airtight protection on duplicate-bearing data needs SERIALIZABLE
    # isolation or external dedup. Ash-managed creates enforce UUID uniqueness, so
    # duplicates only arise from external corruption.
    with :ok <- precheck_no_duplicate_pk(query, label, pk_fields, resource) do
      run_update_set(query, label, set_str, changed_attrs, atomic_params, resource, return_records?, single_record?)
    end
  end

  defp precheck_no_duplicate_pk(query, label, pk_fields, resource) do
    {check_cypher, check_params} = AshAge.Query.duplicate_pk_cypher(query, label, pk_fields)

    case build_and_query(query.repo, query.graph, check_cypher, check_params) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, _} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason:
             "bulk update would match multiple rows for one primary key (duplicate rows in graph?)"
         )}

      {:error, error} ->
        {:error, QueryFailed.exception(query: "AGE duplicate-PK precheck", reason: redact_db_error(error))}
    end
  end

  defp run_update_set(
         query,
         label,
         set_str,
         changed_attrs,
         atomic_params,
         resource,
         return_records?,
         single_record?
       ) do
    {cypher, where_params} = AshAge.Query.update_cypher(query, label, set_str)

    # Drop the changed-attribute reservation seeds (reserve_attr_params) so the
    # real SET values in `changed_attrs` win the merge. Filter/PK/tenant params
    # were allocated as `$paramN` SKIPPING attr names, so they survive — only the
    # `nil` seeds for changed attrs are removed.
    where_params = Map.drop(where_params, Map.keys(changed_attrs))
    params = changed_attrs |> Map.merge(where_params) |> Map.merge(atomic_params)

    case build_and_query(query.repo, query.graph, cypher, params, [{:n, :agtype}]) do
      {:ok, %{rows: rows}} ->
        decoded = decode_records(resource, rows)

        if single_record? and length(decoded) > 1 do
          # Defense-in-depth + Ash contract: the pre-write check should have
          # caught a duplicate, but a concurrent insert between check and SET
          # could slip through; Ash's per-record wrapper requires exactly one
          # record regardless (update.ex:210).
          duplicate_pk_error(resource, length(decoded))
        else
          # Bulk path. The pre-write check already rejected duplicate-PK writes;
          # the post-write fail_closed_on_duplicate_pk here is defense-in-depth
          # for the same check→SET race (returns the records, or :ok).
          bulk_update_result(resource, decoded, return_records?)
        end

      {:error, error} ->
        {:error, QueryFailed.exception(query: "AGE update_query", reason: redact_db_error(error))}
    end
  end

  # Multi-row vertex decode (the read-path pattern from run_query_body). NOT the
  # single-row decode_update_result/3 (whose [_, _|_] clause errors on 2+ rows as
  # a per-record duplicate-PK guard — plan-review S3).
  defp decode_records(resource, rows) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    Enum.map(rows, fn [agtype_text] ->
      agtype_text
      |> Agtype.decode()
      |> Cast.vertex_to_resource_attrs(attribute_map, attribute_types)
      |> then(&struct(resource, &1))
    end)
  end

  # === Transaction Support ===

  @impl true
  def transaction(resource, fun, _timeout \\ nil, _reason \\ nil) do
    repo = Info.repo(resource)
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(repo, :transaction, [fun])
  end

  @impl true
  def in_transaction?(resource) do
    repo = Info.repo(resource)
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(repo, :in_transaction?, [])
  end

  @impl true
  def rollback(resource, value) do
    repo = Info.repo(resource)
    repo.rollback(value)
  end

  # === Filter/Sort/Limit/Offset ===

  @impl true
  def filter(query, filter, resource) do
    # Reserve every attribute name BEFORE translating the filter so the filter's
    # `$paramN` allocations (Query.add_param → next_param_key) can never pick a
    # name that a SET attribute uses. Without this, an attribute literally named
    # `param<N>` would share its `$paramN` ref between the WHERE and the SET on
    # the bulk-update path (filter translated here at query-build, before SET
    # attrs are known) — a silent wrong-write (cross-vendor finding). The
    # per-record path already reserves changed_attrs in `changeset_where`; this
    # covers the bulk path + reads. Seeds are `nil` placeholders dropped before
    # the SET merge in run_update_query.
    query = reserve_attr_params(query, resource)

    case Filter.translate(filter, query) do
      {:ok, query, where_clause} ->
        {:ok, %{query | filters: query.filters ++ [where_clause]}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def sort(query, sort, _resource) do
    sort_clauses =
      Enum.map(sort, fn
        {%Ash.Resource.Attribute{name: name}, direction} -> {name, direction}
        {name, direction} when is_atom(name) -> {name, direction}
      end)

    {:ok, %{query | sort: query.sort ++ sort_clauses}}
  end

  @impl true
  def limit(query, limit, _resource) do
    {:ok, %{query | limit: limit}}
  end

  @impl true
  def offset(query, offset, _resource) do
    {:ok, %{query | offset: offset}}
  end

  # === Helpers ===

  @doc false
  # Resolves the AGE graph for a write. Gated on the multitenancy STRATEGY, not on
  # `changeset.to_tenant` presence — `to_tenant` is populated for `:attribute`
  # resources too, so keying off it would misroute `:attribute` writes. For
  # `:context`, a nil/blank tenant FAILS CLOSED — there is no global graph, and
  # falling through to the base graph would be a silent cross-tenant write.
  def write_graph(resource, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :context do
      case Map.get(changeset, :to_tenant) do
        blank when blank in [nil, ""] -> {:error, :tenant_required}
        tenant -> {:ok, AshAge.Multitenancy.graph_name(resource, tenant)}
      end
    else
      {:ok, Info.graph(resource)}
    end
  end

  @doc false
  # Builds the `n.key = $key` SET fragment, validating every property key as an
  # AGE identifier before it is interpolated into the cypher body. Values are
  # always parameterized (referenced as `$key`), never interpolated.
  def set_clauses(props) do
    props
    |> Map.keys()
    |> Enum.map_join(", ", fn key ->
      key = AshAge.Migration.validate_identifier!(key)

      # Backtick-quote the property access: a property whose name collides with a
      # Cypher keyword (`count`, `label`) mis-parses when bare (AGE probe D-row;
      # the same fix the Cypher.Expr translator applies). Harmless for non-keywords.
      "n.`#{key}` = $#{key}"
    end)
  end

  defp validated_label(resource) do
    resource
    |> Info.label()
    |> AshAge.Migration.validate_identifier!()
  end

  # Returns `base`, or `base` with `_` appended until it is free in `taken`,
  # guaranteeing a param name that does not collide with a property key.
  defp unique_key(taken, base) do
    if Map.has_key?(taken, base), do: unique_key(taken, base <> "_"), else: base
  end

  # Resolves `[{pk_field, value}]` from the resource's primary key and the
  # changeset's ORIGINAL data — the identity of the row being updated/destroyed.
  # `get_data/2` (not `get_attribute/2`) is deliberate: a primary-key attribute
  # can be writable and included in an update's `accept` list, in which case
  # `get_attribute/2` would return the PENDING (new) value, and the WHERE clause
  # would match zero rows (the stored row still has the old value) instead of
  # matching the row being renamed. Values are serialized by attribute type so
  # the match param carries the stored wire form (binary-storage → `$age64$`
  # tag, dates → ISO8601) — a raw binary PK would otherwise never match.
  defp pk_pairs(resource, changeset) do
    types = Info.attribute_types(resource)

    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(fn field ->
      value = Ash.Changeset.get_data(changeset, field)
      {field, Cast.serialize_value(value, Map.get(types, field))}
    end)
  end

  @doc false
  # StaleRecord's message inspects its `filter` into logs (Ash stale_record.ex),
  # so the filter carries PK field NAMES only — values are redacted (they can be
  # PII or ciphertext; AGENTS.md rule 5). Public for the unit test and for
  # AshAge.Changes.DestroyEdge (same contract on the edge path).
  def redacted_filter(pairs) do
    Map.new(pairs, fn {field, _value} -> {field, "<redacted>"} end)
  end

  @doc false
  # Builds the primary-key WHERE clause and its params from `[{field, value}]`
  # pairs. Each key is validated as an AGE identifier before it is interpolated
  # into the cypher body; values are always parameterized (referenced as
  # `$match_<key>`). `reserved` is a map whose keys are param names already taken
  # (e.g. changed attributes in an update SET) so a match param can never collide.
  def pk_match_clause([], _reserved) do
    raise ArgumentError,
          "AshAge requires a primary key to match on for update/destroy, but the resource declares none"
  end

  def pk_match_clause(pk_pairs, reserved) do
    {clauses, params, _taken} =
      Enum.reduce(pk_pairs, {[], %{}, reserved}, fn {field, value}, {clauses, params, taken} ->
        key = field |> to_string() |> AshAge.Migration.validate_identifier!()
        param = unique_key(taken, "match_#{key}")

        {["n.#{key} = $#{param}" | clauses], Map.put(params, param, value),
         Map.put(taken, param, value)}
      end)

    {clauses |> Enum.reverse() |> Enum.join(" AND "), params}
  end

  @doc false
  # Translates changeset.filter (the tenant/policy scoping Ash attaches for
  # update/destroy) into an additional WHERE fragment, AND-ed with the PK match,
  # reusing the read path's Filter translator. Fails CLOSED on an untranslatable
  # filter — never silently drops scoping. `params` already holds the SET/match
  # params, so the accumulator's $paramN counter starts past them. Public (like
  # `write_graph/2`) so the fail-closed deny path is unit-testable without a DB.
  def changeset_where(changeset, base_where, params) do
    case changeset.filter do
      nil ->
        {:ok, base_where, params}

      filter ->
        case Filter.translate(filter, %AshAge.Query{params: params}) do
          {:ok, %AshAge.Query{params: params}, ""} ->
            {:ok, base_where, params}

          {:ok, %AshAge.Query{params: params}, clause} ->
            {:ok, base_where <> " AND " <> clause, params}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc false
  # Seeds every attribute name (string key, `nil` placeholder) into `query.params`
  # so `Query.add_param`'s `next_param_key` skips them when allocating `$paramN`
  # refs for filters / PK / tenant scoping. Structurally prevents a scoping
  # `$paramN` from sharing a name with a SET attr (`$<attr>`) — which, for an
  # attribute literally named `param<N>`, would bind one value to both the WHERE
  # and the SET (silent wrong-write, cross-vendor finding). Existing real params
  # are preserved (Map.merge: `query.params` wins). The seeds are dropped from
  # `where_params` in `run_update_query` before the SET values merge.
  def reserve_attr_params(query, resource) do
    reserved =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(fn %{name: name} -> {Atom.to_string(name), nil} end)

    %{query | params: Map.merge(reserved, query.params)}
  end

  # Decodes the AGE result of an update's `MATCH ... SET ... RETURN n`. A returned
  # vertex is the updated row; an empty result means the WHERE (PK + scoping
  # filter) matched nothing — the record is gone or a filter excluded it, which is
  # `StaleRecord` per the Ash data-layer contract (NotFound is for identifier
  # lookups; StaleRecord is the record-mutation signal, and Ash's bulk paths
  # pattern-match it). Mirrors the reference ETS data layer.
  defp decode_update_result(resource, _filter, {:ok, %{rows: [[vertex_text]]}}) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    attrs =
      vertex_text
      |> Agtype.decode()
      |> Cast.vertex_to_resource_attrs(attribute_map, attribute_types)

    {:ok, struct(resource, attrs)}
  end

  # AGE enforces no PK uniqueness, so duplicate-keyed vertices are creatable
  # outside Ash; an update WHERE can then match 2+ rows. Fail closed with a
  # value-free reason (the count is structural) — never a FunctionClauseError
  # crossing the callback boundary. Destroy's [_ | _] clause already tolerates
  # this; update must not silently pick one row, so it errors instead. The SET
  # has already applied to every matched row by this point: Ash update actions
  # default `transaction?: true` (and this layer advertises :transact), which
  # rolls the multi-write back — a `transaction? false` action keeps it and
  # only surfaces this error.
  defp decode_update_result(resource, _filter, {:ok, %{rows: [_, _ | _] = rows}}) do
    {:error,
     UpdateFailed.exception(
       resource: resource,
       reason:
         "update matched #{length(rows)} rows for one primary key (duplicate rows in graph?)"
     )}
  end

  defp decode_update_result(resource, filter, {:ok, %{rows: []}}) do
    {:error, StaleRecord.exception(resource: resource, filter: filter)}
  end

  defp decode_update_result(resource, _filter, {:error, error}) do
    {:error, UpdateFailed.exception(resource: resource, reason: redact_db_error(error))}
  end

  # Decodes the AGE result of a destroy's `MATCH ... DETACH DELETE n RETURN n`. At
  # least one returned vertex means a row was deleted; an empty result means the
  # WHERE (PK + scoping filter) matched nothing and fails CLOSED as `StaleRecord`
  # (see decode_update_result/3 for why StaleRecord, not NotFound).
  defp decode_destroy_result(_resource, _filter, {:ok, %{rows: [_ | _]}}), do: :ok

  defp decode_destroy_result(resource, filter, {:ok, %{rows: []}}) do
    {:error, StaleRecord.exception(resource: resource, filter: filter)}
  end

  defp decode_destroy_result(_resource, _filter, {:error, error}) do
    {:error, QueryFailed.exception(query: "AGE delete query", reason: redact_db_error(error))}
  end

  @doc false
  # Redacts a Postgrex error into a value-free reason string. Postgres `DETAIL`
  # lines echo the offending values (e.g. "Key (email)=(a@b.com) already exists"),
  # so we surface only the SQLSTATE name (and constraint identifier when present),
  # never the free-text message/detail/query.
  def redact_db_error(:params_not_json_encodable),
    do: "query parameters not JSON-encodable (raw binary in a non-binary-typed value?)"

  def redact_db_error(%Postgrex.Error{postgres: %{code: code} = pg}) do
    case Map.get(pg, :constraint) do
      nil -> "database error (#{code})"
      constraint -> "database error (#{code}, constraint: #{constraint})"
    end
  end

  def redact_db_error(%Postgrex.Error{}), do: "database connection error"

  # Any other error term (e.g. %DBConnection.ConnectionError{} when the pool is
  # exhausted or the connection drops) is redacted to a value-free generic reason
  # rather than crashing the callback with a CaseClauseError — a crash would
  # surface a stacktrace that can echo the query or its bound values.
  def redact_db_error(_other), do: "database error"

  @doc false
  # Pre-checks that every serialized property is JSON-encodable, returning the
  # OFFENDING ATTRIBUTE NAME (structural, safe to surface) — never the value.
  # Raw bytes are only JSON-safe at binary-storage-typed attributes (tagged by
  # serialize_value); nested inside a :map/:list value they would raise
  # Jason.EncodeError from Parameterized.build with the bytes in the message.
  # Public so the unit suite exercises the seam without a DB.
  def encode_check(props) do
    case Enum.find(props, fn {_key, value} -> match?({:error, _}, Jason.encode(value)) end) do
      nil -> :ok
      {key, _value} -> {:error, String.to_atom(key)}
    end
  end

  @doc false
  # First offending attribute name across a bulk batch's `{changeset, props}`
  # entries, or nil when every row passes encode_check/1. Public (like its
  # encode_check/build_and_query siblings) so the unit suite can go red at the
  # bulk gate seam without a DB.
  def first_encode_failure(entries) do
    Enum.find_value(entries, fn {_cs, props} ->
      case encode_check(props) do
        {:error, attr} -> attr
        :ok -> nil
      end
    end)
  end

  defp encode_error_reason(attr) do
    "attribute #{inspect(attr)} is not JSON-encodable (raw binary nested in a " <>
      ":map/:list value? encode it app-side, e.g. Base.encode64, or store it " <>
      "in a :binary-typed attribute)"
  end

  @doc false
  # The data layer's build+execute seam: a non-JSON-encodable param fails closed
  # as a value-free tuple BEFORE any SQL runs, instead of a raise (whose message
  # embeds the bytes — AGENTS.md rule 5) crossing the callback boundary. The
  # rescue classifier itself lives ONCE in Parameterized.safe_build/4. Public so
  # the unit suite can poison the params without a DB (the failure happens at
  # build time, before the repo is touched).
  def build_and_query(repo, graph, cypher, params, return_types \\ [{:v, :agtype}]) do
    case Parameterized.safe_build(graph, cypher, params, return_types) do
      {:ok, {sql, pg_params}} -> SQL.query(repo, sql, pg_params)
      {:error, :params_not_json_encodable} = error -> error
    end
  end

  defp changeset_to_properties(resource, changeset) do
    skip = Info.skip(resource)
    types = Info.attribute_types(resource)

    changeset.attributes
    |> Enum.reject(fn {key, _} -> key in skip end)
    |> Enum.map(fn {key, value} ->
      {Atom.to_string(key), serialize_value(value, Map.get(types, key))}
    end)
    |> Map.new()
  end

  @doc false
  # Delegates to AshAge.Type.Cast.serialize_value/2 — the encoder moved to Cast
  # (level 2) in S7 so Query.Filter (level 3) can share it. Kept as a shim so
  # existing callers keep their entry point.
  def serialize_value(value, type), do: Cast.serialize_value(value, type)

  # Resolves the AGE graph for a bulk batch. An empty batch has no changeset to
  # read `to_tenant` from, so there is nothing to write and the base graph is
  # harmless (do_bulk_create short-circuits on empty). A non-empty batch resolves
  # via write_graph/2 off the first changeset — Ash batches by tenant, so all
  # changesets in a batch share the same tenant/graph, and this reuses the exact
  # fail-closed nil-:context-tenant path single-create uses.
  defp bulk_graph(resource, []), do: {:ok, Info.graph(resource)}
  defp bulk_graph(resource, [{changeset, _props} | _]), do: write_graph(resource, changeset)

  defp do_bulk_create(_resource, _graph, [], _opts), do: :ok

  defp do_bulk_create(resource, graph, entries, opts) do
    repo = Info.repo(resource)
    label = validated_label(resource)
    return_records? = Map.get(opts, :return_records?, false)

    # Group by key-set so each UNWIND CREATE emits SET clauses for exactly the
    # keys present in that group — no null-fill across differently-shaped rows.
    # Property maps are paired with their changeset so returned vertices can be
    # stamped with the changeset's bulk_create_index for Ash's record→changeset
    # mapping.
    entries
    |> group_bulk_entries()
    |> Enum.reduce_while({:ok, []}, fn {keys, group_entries}, {:ok, acc} ->
      case run_bulk_group(resource, graph, repo, label, keys, group_entries, return_records?) do
        {:ok, records} -> {:cont, {:ok, acc ++ records}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _records} when not return_records? -> :ok
      {:ok, records} -> {:ok, records}
      {:error, error} -> {:error, error}
    end
  end

  # Runs one key-set group's UNWIND CREATE. `keys` are the property keys shared by
  # every row in the group; each is validated as an AGE identifier before it is
  # interpolated into the SET clause. Row values are carried as a single list
  # param `$rows` (an agtype array of maps) — serialize_value has already tagged
  # binary/date values so they round-trip through Jason.encode! + AGE.
  defp run_bulk_group(resource, graph, repo, label, keys, group_entries, return_records?) do
    rows = Enum.map(group_entries, fn {_cs, props} -> props end)

    set_clause =
      Enum.map_join(keys, ", ", fn key ->
        key = AshAge.Migration.validate_identifier!(key)
        "n.#{key} = row.#{key}"
      end)

    cypher =
      if set_clause == "" do
        "UNWIND $rows AS row CREATE (n:#{label}) RETURN n"
      else
        "UNWIND $rows AS row CREATE (n:#{label}) SET #{set_clause} RETURN n"
      end

    case build_and_query(repo, graph, cypher, %{"rows" => rows}) do
      {:ok, %{rows: result_rows}} ->
        cond do
          not return_records? ->
            {:ok, []}

          # AGE CREATE per UNWIND row is 1:1, so the returned vertex count MUST
          # equal the group's row count. A mismatch is a should-never-happen
          # invariant, but zipping would silently truncate/misalign the
          # record→changeset mapping (corrupting bulk_create_index stamping), so
          # fail the whole batch LOUD instead — mirroring single-create's strict
          # row-shape match.
          length(result_rows) != length(group_entries) ->
            {:error,
             CreateFailed.exception(
               resource: resource,
               reason:
                 "bulk create returned #{length(result_rows)} rows for " <>
                   "#{length(group_entries)} changesets (row-count mismatch)"
             )}

          true ->
            {:ok, decode_bulk_records(resource, group_entries, result_rows)}
        end

      {:error, error} ->
        {:error, CreateFailed.exception(resource: resource, reason: redact_db_error(error))}
    end
  end

  # Decodes each returned vertex to a record and stamps it with its originating
  # changeset's bulk metadata (`bulk_create_index` + `bulk_action_ref`). P4a
  # proves UNWIND preserves per-group input order, so the Nth returned vertex
  # corresponds to the Nth entry in this group; Ash then reassembles cross-group
  # order via `bulk_create_index`.
  defp decode_bulk_records(resource, group_entries, result_rows) do
    attribute_map = Info.attribute_map(resource)
    attribute_types = Info.attribute_types(resource)

    group_entries
    |> Enum.zip(result_rows)
    |> Enum.map(fn {{changeset, _props}, [vertex_text]} ->
      attrs =
        vertex_text
        |> Agtype.decode()
        |> Cast.vertex_to_resource_attrs(attribute_map, attribute_types)

      record = struct(resource, attrs)

      %{record | __meta__: %Metadata{state: :loaded, schema: resource}}
      |> BulkHelpers.put_metadata(changeset)
    end)
  end

  @doc false
  # Groups a list of `{changeset, property_map}` entries by their key-set (the set
  # of property keys), preserving intra-group input order. Returns
  # `[{keys, entries}]` where `keys` is the sorted list of that group's property
  # keys. Distinct key-sets become distinct groups so a bulk UNWIND never has to
  # null-fill a property absent from some rows.
  def group_bulk_entries(entries) do
    entries
    |> Enum.group_by(fn {_cs, props} -> props |> Map.keys() |> Enum.sort() end)
    |> Map.to_list()
  end

  @doc false
  # Group a list of bare property maps by key-set. Public seam for the unit test
  # of the grouping logic (no changesets, no DB). Returns `[{keys, rows}]`.
  def group_bulk_rows(rows) do
    rows
    |> Enum.map(fn props -> {nil, props} end)
    |> group_bulk_entries()
    |> Enum.map(fn {keys, entries} -> {keys, Enum.map(entries, fn {_cs, props} -> props end)} end)
  end

  @doc false
  # RLS wrapper. Off → {:ok, fun_result}. On + blank tenant → {:error,
  # :rls_tenant_required} (fail-closed BEFORE any query). On + tenant → runs fun
  # inside repo.transaction after set_config; the transaction PINS one connection,
  # so the GUC and the cypher execute on the same backend. On success returns
  # {:ok, fun_result}. Any transaction/rollback failure — a set_config rollback,
  # a bare `{:error, :rollback}` from the driver, or a failed COMMIT — surfaces as
  # some `{:error, _}` term that unwrap_rls/2 normalizes into a redacted
  # {:error, %QueryFailed{}}. set_config binds both args as params (never interpolated).
  def with_rls(resource, tenant, repo, fun) do
    case Info.rls_guc(resource) do
      nil ->
        {:ok, fun.()}

      _guc when tenant in [nil, ""] ->
        {:error, :rls_tenant_required}

      guc ->
        repo.transaction(fn -> set_rls_guc_then(guc, tenant, repo, fun) end)
    end
  end

  # Runs inside repo.transaction: set the GUC on this pinned connection, then run
  # fun on the SAME backend. A set_config failure rolls back with a redacted error.
  defp set_rls_guc_then(guc, tenant, repo, fun) do
    case SQL.query(repo, "SELECT set_config($1, $2, true)", [guc, to_string(tenant)]) do
      {:ok, _} ->
        fun.()

      {:error, error} ->
        repo.rollback(
          QueryFailed.exception(query: "RLS set_config", reason: redact_db_error(error))
        )
    end
  end

  @doc false
  # Maps with_rls/4's contract to a data-layer callback result.
  def unwrap_rls({:ok, result}, _resource), do: result

  def unwrap_rls({:error, :rls_tenant_required}, resource) do
    {:error,
     QueryFailed.exception(
       query: "RLS-scoped operation",
       reason: "multitenancy tenant required for RLS-protected #{inspect(resource)}"
     )}
  end

  def unwrap_rls({:error, %{__exception__: true} = exception}, _resource), do: {:error, exception}

  # Catch-all keeps unwrap_rls/2 TOTAL. repo.transaction/2 (db_connection under
  # ecto_sql) can return a bare `{:error, :rollback}` (or a DBConnection.TransactionError
  # on a failed COMMIT) that matches none of the clauses above; without this, the
  # data-layer callback would crash with FunctionClauseError and leak a stacktrace
  # that can echo the query/values — the exact failure redact_db_error/1 guards
  # against. The reason is static and value-free: never interpolate the raw error.
  def unwrap_rls({:error, _other}, _resource) do
    {:error,
     QueryFailed.exception(
       query: "RLS-scoped operation",
       reason: "database error during RLS-scoped operation"
     )}
  end

  # === Telemetry span helpers (value-free metadata only) ===

  defp strategy(resource), do: Ash.Resource.Info.multitenancy_strategy(resource)
  defp tenant?(changeset), do: not is_nil(Map.get(changeset, :to_tenant))
  defp rls?(resource), do: not is_nil(Info.rls_guc(resource))
  defp row_count({:ok, records}), do: length(records)
  defp row_count(_), do: 0
  defp stale?({:error, %StaleRecord{}}), do: true
  defp stale?(_), do: false
end
