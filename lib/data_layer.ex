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
    label :MyLabel   # optional, defaults to module short module name
    skip [:computed]  # optional, properties to exclude from AGE
    sensitive [:ssn]  # optional, classified attributes (binary-storage or skipped)

    edge :related_to do
      label :RELATES_TO
      direction :outgoing
      destination MyApp.OtherResource
    end
  end
  ```
  """

  require Spark.Dsl
  require Spark.Dsl.Entity

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
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer.Info
  alias AshAge.Errors.{CreateFailed, QueryFailed, UpdateFailed}
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
  def can?(_, {:filter_expr, _}), do: false
  def can?(_, :upsert), do: false
  def can?(_, :bulk_create), do: true
  def can?(_, {:lateral_join, _}), do: false
  def can?(_, {:aggregate, _}), do: false
  def can?(_, :multitenancy), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :changeset_filter), do: true
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
    set_clauses = set_clauses(changed_attrs)

    # Match on the resource's full primary key (composite or non-:id supported).
    # `changed_attrs` are reserved so a match param never clobbers a SET param.
    pk = pk_pairs(resource, changeset)
    {where_clause, match_params} = pk_match_clause(pk, changed_attrs)

    case changeset_where(changeset, where_clause, Map.merge(changed_attrs, match_params)) do
      {:ok, full_where, params} ->
        cypher = """
        MATCH (n:#{label})
        WHERE #{full_where}
        SET #{set_clauses}
        RETURN n
        """

        decode_update_result(
          resource,
          redacted_filter(pk),
          build_and_query(repo, graph, cypher, params)
        )

      {:error, _} ->
        {:error,
         UpdateFailed.exception(
           resource: resource,
           reason: "unsupported scoping filter on update"
         )}
    end
  end

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
  def filter(query, filter, _resource) do
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
      "n.#{key} = $#{key}"
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
  # this; update must not silently pick one row, so it errors instead.
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
