defmodule AshAge.Query do
  @moduledoc """
  Query structure for AGE graph queries.
  """

  defstruct [
    :resource,
    :graph,
    :label,
    :repo,
    :tenant,
    :expression,
    :limit,
    :offset,
    filters: [],
    sort: [],
    params: %{},
    aggregates: []
  ]

  @type t :: %__MODULE__{
          resource: module(),
          graph: atom() | String.t(),
          label: atom() | String.t(),
          repo: module(),
          tenant: term() | nil,
          expression: Ash.Filter.t() | nil,
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          filters: [String.t()],
          sort: [{atom(), :asc | :desc}],
          params: map(),
          aggregates: [Ash.Query.Aggregate.t()]
        }

  @doc """
  Converts a query to Cypher with parameters.

  Returns `{cypher_string, params_map}`.
  """
  @spec to_cypher(t()) :: {String.t(), map()}
  def to_cypher(%__MODULE__{} = query) do
    # Defense-in-depth: `label` feeds the cypher body and is only otherwise
    # validated at compile time — re-assert it here so a non-identifier can never
    # inject Cypher or break AGE dollar-quoting.
    label = AshAge.Migration.validate_identifier!(query.label)
    {where_parts, query} = build_where(query)

    parts =
      ["MATCH (n:#{label})"] ++
        build_where_clause(where_parts) ++
        ["RETURN n"] ++
        build_order_by(query.sort) ++
        build_skip(query.offset) ++
        build_limit(query.limit)

    {Enum.join(parts, " "), query.params}
  end

  @doc """
  Builds the Cypher for a single aggregate over the query's filtered set.

  `MATCH (n:LABEL) WHERE <main filter> [AND <aggregate sub-filter>] RETURN <expr> AS agg`.
  Deliberately emits NO `LIMIT`/`SKIP`/`ORDER BY` even when the query carries them
  (the AshPostgres/ETS contract): an aggregate is computed over the FULL filtered
  set, not a page of it. The aggregate's own sub-query filter (its `query` field)
  is AND-ed into the WHERE so each aggregate narrows independently (one query is
  issued per aggregate by `run_aggregate_query/3`).
  """
  @spec aggregate_cypher(t(), Ash.Query.Aggregate.t(), atom() | String.t()) ::
          {String.t(), map()}
  def aggregate_cypher(query, aggregate, label) do
    label = AshAge.Migration.validate_identifier!(label)

    {main_parts, query} = build_where(query)
    {sub_parts, query} = sub_filter_clause(aggregate, query)
    where_parts = main_parts ++ sub_parts

    expr = AshAge.Query.Aggregate.expr({aggregate.kind, aggregate.field, uniq_opts(aggregate)})

    parts =
      ["MATCH (n:#{label})"] ++
        build_where_clause(where_parts) ++
        ["RETURN #{expr} AS agg"]

    {Enum.join(parts, " "), query.params}
  end

  # The aggregate's own sub-query filter → a WHERE fragment via the read-path
  # Filter translator. `aggregate.query` may be an Ash.Query (resolved), a keyword
  # list (resolved later by Ash — treated as no sub-filter here), or nil.
  defp sub_filter_clause(%Ash.Query.Aggregate{query: %Ash.Query{} = agg_query} = _agg, query) do
    case agg_query.filter do
      nil -> {[], query}
      filter -> translate_sub_filter(filter, query)
    end
  end

  defp sub_filter_clause(_agg, query), do: {[], query}

  defp translate_sub_filter(filter, query) do
    case AshAge.Query.Filter.translate(filter, query) do
      {:ok, query, ""} ->
        {[], query}

      {:ok, query, clause} ->
        {[clause], query}

      # Fail CLOSED: silently dropping an aggregate sub-filter would broaden the
      # set (a count meant to be narrowed) — a silent-correctness leak. The
      # UnsupportedFilter is structural (operator + field), value-free, so safe
      # to raise across the callback boundary (AGENTS.md rule 5).
      {:error, %AshAge.Errors.UnsupportedFilter{} = err} ->
        raise err
    end
  end

  defp uniq_opts(%Ash.Query.Aggregate{uniq?: true}), do: [uniq?: true]
  defp uniq_opts(_), do: []

  @doc """
  Builds the Cypher for a bulk destroy by query.

  `MATCH (n:LABEL) WHERE <translated filter> [WITH n SKIP .. LIMIT ..] DETACH DELETE n`.
  Uses the SAME `build_where` as the read path, so destroy_query deletes exactly the
  rows a read would return — including the tenant predicate Ash attaches for
  `:attribute` multitenancy. LIMIT/SKIP are honored via a `WITH n` pass-through:
  Ash does NOT slice the query above the data layer for destroy_query
  (`bulk.ex:622-723 do_atomic_destroy` passes it through), so a user-supplied limit
  must bound the deletion here or it over-deletes (the ETS `destroy_query` reference
  honors limit too). No `ORDER BY`: without a deterministic sort, which rows die is
  unspecified — same as ETS, which sorts by PK only.
  """
  @spec delete_cypher(t(), atom() | String.t()) :: {String.t(), map()}
  def delete_cypher(query, label) do
    label = AshAge.Migration.validate_identifier!(label)
    {where_parts, query} = build_where(query)

    base = ["MATCH (n:#{label})"] ++ build_where_clause(where_parts)

    delete =
      if query.limit == nil and query.offset == nil do
        ["DETACH DELETE n"]
      else
        # `WITH n` passes the WHERE-matched set into the ORDER BY/SKIP/LIMIT,
        # bounding the DETACH DELETE to the limited slice (standard Cypher).
        # ORDER BY is honored when present so a sorted+limited destroy deletes
        # the deterministically-sorted slice, not an arbitrary one.
        ["WITH n"] ++
          build_order_by(query.sort) ++
          build_skip(query.offset) ++
          build_limit(query.limit) ++
          ["DETACH DELETE n"]
      end

    {Enum.join(base ++ delete, " "), query.params}
  end

  @doc """
  Builds the bulk-update Cypher for `update_query/4`: applies one set of changes
  (plain attributes + translated atomics) to every record the query matches.

  Mirrors `delete_cypher/2`, replacing `DETACH DELETE n` with `SET <clauses> RETURN n`.
  Scoping source is `build_where(query)` — the `:attribute` tenant predicate arrives
  in `query.expression` via Ash's `handle_attribute_multitenancy` (NOT `changeset.filter`,
  which Ash nils into `query.filter` before the data layer runs — adversarial Challenge 1).
  LIMIT/SKIP honored via the same `WITH n` pass-through as destroy_query.
  `RETURN n` so updated records can be decoded when `return_records?` is set.
  """
  @spec update_cypher(t(), atom() | String.t(), String.t()) :: {String.t(), map()}
  def update_cypher(query, label, set_clauses_str) do
    label = AshAge.Migration.validate_identifier!(label)
    {where_parts, query} = build_where(query)

    base = ["MATCH (n:#{label})"] ++ build_where_clause(where_parts)

    body =
      if query.limit == nil and query.offset == nil do
        ["SET #{set_clauses_str}", "RETURN n"]
      else
        # `WITH n` passes the WHERE-matched set into the ORDER BY/SKIP/LIMIT.
        # ORDER BY is honored when present so a sorted+limited bulk_update updates
        # the deterministically-sorted slice, not an arbitrary one (cross-vendor
        # closeout finding: SKIP/LIMIT without ORDER BY selected arbitrary rows).
        ["WITH n"] ++
          build_order_by(query.sort) ++
          build_skip(query.offset) ++
          build_limit(query.limit) ++
          ["SET #{set_clauses_str}", "RETURN n"]
      end

    {Enum.join(base ++ body, " "), query.params}
  end

  @doc """
  Adds a parameter to the query, returning the updated query and a `$paramN` reference.
  """
  @spec add_param(t(), term()) :: {t(), String.t()}
  def add_param(%__MODULE__{params: params} = query, value) do
    key = next_param_key(params, map_size(params) + 1)
    {%{query | params: Map.put(params, key, value)}, "$#{key}"}
  end

  # Returns the next free `paramN` key, skipping any already taken. A resource
  # attribute literally named `param<N>` shares this namespace with a filter/PK
  # scoping param, so `AshAge.DataLayer.reserve_attr_params/2` pre-seeds every
  # attribute name into `query.params` (in `filter/3` and `update_many_group`)
  # BEFORE any scoping-param allocation — this skip then never lands on an attr
  # name, and the SET attrs (`$<attr>`) stay disjoint from scoping (`$paramN`).
  # The per-record path pre-seeds `match_<pk>` + changed-attr keys in
  # `changeset_where`. The reservation seeds are dropped from WHERE params in
  # `run_update_query` so the real SET values win the merge.
  defp next_param_key(params, n) do
    key = "param#{n}"
    if Map.has_key?(params, key), do: next_param_key(params, n + 1), else: key
  end

  defp build_where(query) do
    filter_clauses = query.filters

    {expression_clauses, query} =
      if query.expression do
        case AshAge.Query.Filter.translate(query.expression, query) do
          {:ok, query, ""} -> {[], query}
          {:ok, query, clause} -> {[clause], query}
          _ -> {[], query}
        end
      else
        {[], query}
      end

    {filter_clauses ++ expression_clauses, query}
  end

  defp build_where_clause([]), do: []

  defp build_where_clause(parts) do
    ["WHERE " <> Enum.join(parts, " AND ")]
  end

  defp build_order_by([]), do: []

  defp build_order_by(sort_clauses) do
    order =
      Enum.map_join(sort_clauses, ", ", fn {field, direction} ->
        # Field names are interpolated into the cypher body — validate AND
        # backtick-quote (a Cypher-keyword field like `count` collides with the
        # count() aggregate, same as property refs elsewhere). Any `:desc*`
        # direction is DESC (`:desc_nils_first`/`:desc_nils_last` are descending
        # variants — AGE has no NULLS FIRST/LAST syntax, so map to DESC, NOT ASC).
        field = AshAge.Migration.validate_identifier!(field)
        dir = if is_atom(direction) and String.starts_with?(to_string(direction), "desc"),
               do: "DESC",
               else: "ASC"

        "n.`#{field}` #{dir}"
      end)

    ["ORDER BY " <> order]
  end

  defp build_skip(nil), do: []
  defp build_skip(offset) when is_integer(offset) and offset >= 0, do: ["SKIP #{offset}"]

  defp build_skip(offset) do
    raise ArgumentError, "invalid offset: #{inspect(offset)} (expected a non-negative integer)"
  end

  defp build_limit(nil), do: []
  defp build_limit(limit) when is_integer(limit) and limit >= 0, do: ["LIMIT #{limit}"]

  defp build_limit(limit) do
    raise ArgumentError, "invalid limit: #{inspect(limit)} (expected a non-negative integer)"
  end
end
