defmodule AshAge.ManualRelationships.Traverse do
  @moduledoc """
  Bounded variable-length graph traversal as an Ash manual relationship.

      has_many :descendants, MyApp.Node do
        manual {AshAge.ManualRelationships.Traverse,
                edge_label: :PARENT_OF, direction: :outgoing, max_depth: 3, min_depth: 1}
      end

  `load/3` emits `UNWIND $ids AS sid MATCH (a)<pattern>(b) WHERE a.<pk> = sid.<pk>
  … RETURN a.<pk> AS s1[, …], b`, riding the P1-proven list-param UNWIND
  + map-access mechanism, and returns an F3 source-PK-keyed map of materialized
  destination records (deduped per source, cardinality-aware). No SQL `DISTINCT`
  is used: per-path rows are returned raw so `row_count` is the genuine pre-dedup
  fan-out signal (§5.4); dedup is done in Elixir by `dedup/2` (keyed by dest PK),
  which yields `destination_count`. Direction from
  `direction` (`:both` is undirected). Tenancy is FAIL-CLOSED: `:context` resolves
  a per-tenant graph; `:attribute` scopes EVERY node on the path via a fixed-length
  UNION expansion — one basic-MATCH branch per length in `min..max`, each binding
  every node (`a`, unlabeled intermediates `m1..m(len-1)`, `b`) and AND-ing
  `<node>.<attr> = $tenant`, the branches UNIONed (`UNWIND` repeated per branch).
  This AGE build's Cypher parser rejects a bound path variable + `ALL(n IN nodes(p)
  WHERE …)` (probe P-S5b), so the per-hop predicate is unavailable; the UNION
  expansion is the equivalent, probe-validated (P-S5b-UNION) scoping. Values reach
  Cypher only as parameters; every identifier is `validate_identifier!`-checked.
  """
  @behaviour Ash.Resource.ManualRelationship

  alias Ash.Resource.ManualRelationship.Context
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer
  alias AshAge.DataLayer.Info
  alias AshAge.Errors.QueryFailed
  alias AshAge.Migration
  alias AshAge.Multitenancy
  alias AshAge.Telemetry
  alias AshAge.Type.{Agtype, Cast}
  alias Ecto.Adapters.SQL
  alias Ecto.Schema.Metadata

  @impl true
  def select(_opts), do: []

  @impl true
  def load([], _opts, _context), do: {:ok, %{}}

  def load(records, opts, %Context{} = context) do
    source = context.relationship.source
    dest = context.relationship.destination
    card = context.relationship.cardinality
    {_edge_label, direction, _min_depth, max_depth} = opts_tuple = validate_opts!(opts)

    Telemetry.span(
      :traverse,
      %{resource: source, multitenancy: strategy(source), direction: direction},
      fn ->
        {result, row_count} = do_load(records, context, source, dest, card, opts_tuple)

        {result, stop_meta(result, row_count, max_depth)}
      end
    )
  end

  @doc false
  # Validates the manual opts. Raises a value-free ArgumentError on any bad value
  # (config/programmer error → surfaces as a :traverse :exception event). Returns
  # {edge_label_atom, direction, min_depth, max_depth}.
  def validate_opts!(opts) do
    edge_label =
      Keyword.get(opts, :edge_label) || raise ArgumentError, "traverse requires :edge_label"

    _ = Migration.validate_identifier!(edge_label)
    direction = Keyword.get(opts, :direction, :outgoing)

    unless direction in [:outgoing, :incoming, :both],
      do: raise(ArgumentError, "traverse :direction must be :outgoing | :incoming | :both")

    max_depth = Keyword.get(opts, :max_depth)
    min_depth = Keyword.get(opts, :min_depth, 1)

    unless is_integer(max_depth) and max_depth >= 1,
      do:
        raise(
          ArgumentError,
          "traverse :max_depth must be an integer >= 1 (unbounded `*` is forbidden)"
        )

    unless is_integer(min_depth) and min_depth >= 1 and min_depth <= max_depth,
      do:
        raise(
          ArgumentError,
          "traverse :min_depth must be an integer with 1 <= min_depth <= max_depth"
        )

    {edge_label, direction, min_depth, max_depth}
  end

  defp do_load(
         records,
         context,
         source,
         dest,
         card,
         {edge_label, direction, min_depth, max_depth}
       ) do
    with {:ok, graph} <- resolve_graph(source, dest, context.tenant),
         {:ok, tenant_attr, tenant} <- resolve_tenant(dest, context.tenant) do
      src_pkey = Ash.Resource.Info.primary_key(source)
      ids = Enum.uniq(Enum.map(records, fn r -> stringify_keys(Map.take(r, src_pkey)) end))

      spec = %{
        direction: direction,
        edge_label: edge_label,
        min_depth: min_depth,
        max_depth: max_depth,
        src_label: Info.label(source),
        dest_label: Info.label(dest),
        src_pkey: src_pkey,
        tenant_attr: tenant_attr,
        tenant: tenant,
        per_hop_scope?: not is_nil(tenant_attr),
        ids: ids
      }

      {cypher, params} = build_traverse(spec)
      {sql, pg_params} = Parameterized.build(graph, cypher, params, return_types(src_pkey))
      dest_pkey = Ash.Resource.Info.primary_key(dest)

      case SQL.query(Info.repo(source), sql, pg_params) do
        {:ok, %{rows: rows}} ->
          {{:ok,
            assemble_rows(
              rows,
              %{
                src_pkey: src_pkey,
                src_types: Info.attribute_types(source),
                dest_pkey: dest_pkey,
                dest: dest
              },
              card
            )}, length(rows)}

        {:error, error} ->
          {{:error,
            QueryFailed.exception(
              query: "AGE traversal",
              reason: DataLayer.redact_db_error(error)
            )}, 0}
      end
    else
      # fail-closed graph/tenant resolution short-circuit — no rows transferred.
      {:error, _} = error -> {error, 0}
    end
  end

  # --- graph + tenant resolution (fail-closed) ---

  defp resolve_graph(source, _dest, tenant) do
    if strategy(source) == :context do
      case blank_tenant(tenant) do
        :blank -> {:error, tenant_required()}
        :ok -> {:ok, Multitenancy.graph_name(source, tenant)}
      end
    else
      {:ok, Info.graph(source)}
    end
  end

  defp resolve_tenant(dest, tenant) do
    if strategy(dest) == :attribute do
      case blank_tenant(tenant) do
        :blank -> {:error, tenant_required()}
        :ok -> {:ok, to_string(Ash.Resource.Info.multitenancy_attribute(dest)), tenant}
      end
    else
      {:ok, nil, nil}
    end
  end

  defp blank_tenant(t) when t in [nil, ""], do: :blank
  defp blank_tenant(_), do: :ok

  defp tenant_required,
    do: QueryFailed.exception(query: "AGE traversal", reason: "multitenancy tenant required")

  # --- pure Cypher builder (unit-tested) ---

  @doc false
  def build_traverse(spec) do
    edge_label = Migration.validate_identifier!(spec.edge_label)
    src_label = Migration.validate_identifier!(spec.src_label)
    dest_label = Migration.validate_identifier!(spec.dest_label)
    src_match = src_match(spec.src_pkey)
    src_return = src_return(spec.src_pkey)

    if spec.per_hop_scope? do
      # :attribute — AGE lacks ALL(nodes(p)) (probe P-S5b), so expand to a
      # fixed-length UNION: one basic-MATCH branch per length, every node scoped
      # to $tenant, UNWIND repeated per branch (P-S5b-UNION validated this shape).
      # UNION ALL (not UNION) preserves per-path fan-out across branches so
      # `row_count` stays pre-dedup; Elixir `dedup/2` is the final dedup.
      attr = Migration.validate_identifier!(spec.tenant_attr)

      cypher =
        Enum.map_join(spec.min_depth..spec.max_depth, " UNION ALL ", fn len ->
          union_branch(
            spec.direction,
            src_label,
            dest_label,
            edge_label,
            len,
            attr,
            src_match,
            src_return
          )
        end)

      {cypher, %{"ids" => spec.ids, "tenant" => spec.tenant}}
    else
      # :context / no multitenancy — the P-S5a-proven single variable-length MATCH.
      pattern =
        pattern(spec.direction, src_label, dest_label, edge_label, spec.min_depth, spec.max_depth)

      cypher =
        "UNWIND $ids AS sid " <>
          "MATCH #{pattern} " <>
          "WHERE #{src_match} " <>
          "RETURN #{src_return}, b"

      {cypher, %{"ids" => spec.ids}}
    end
  end

  defp pattern(:incoming, src, dest, label, min, max),
    do: "(a:#{src})<-[:#{label}*#{min}..#{max}]-(b:#{dest})"

  defp pattern(:both, src, dest, label, min, max),
    do: "(a:#{src})-[:#{label}*#{min}..#{max}]-(b:#{dest})"

  defp pattern(_outgoing, src, dest, label, min, max),
    do: "(a:#{src})-[:#{label}*#{min}..#{max}]->(b:#{dest})"

  # One fixed-length UNION branch: an explicit `len`-edge chain a→m1→…→b with
  # (len-1) unlabeled intermediates, every node AND-scoped to $tenant. UNWIND is
  # repeated per branch because AGE requires each UNION query part self-contained.
  defp union_branch(direction, src, dest, label, len, attr, src_match, src_return) do
    {chain, node_vars} = fixed_chain(direction, src, dest, label, len)
    scope = Enum.map_join(node_vars, " AND ", fn v -> "#{v}.#{attr} = $tenant" end)

    "UNWIND $ids AS sid " <>
      "MATCH #{chain} " <>
      "WHERE #{src_match} AND #{scope} " <>
      "RETURN #{src_return}, b"
  end

  # Builds a fixed `len`-edge chain and the list of node variables to scope.
  # len == 1 => "(a:src)<edge>(b:dest)", vars [a, b]; len == 3 =>
  # "(a:src)<edge>(m1)<edge>(m2)<edge>(b:dest)", vars [a, m1, m2, b].
  defp fixed_chain(direction, src, dest, label, len) do
    inter = if len > 1, do: Enum.map(1..(len - 1), &"m#{&1}"), else: []
    vars = ["a" | inter] ++ ["b"]

    decorated =
      Enum.map(vars, fn
        "a" -> "(a:#{src})"
        "b" -> "(b:#{dest})"
        v -> "(#{v})"
      end)

    {Enum.join(decorated, edge_fragment(direction, label)), vars}
  end

  defp edge_fragment(:incoming, label), do: "<-[:#{label}]-"
  defp edge_fragment(:both, label), do: "-[:#{label}]-"
  defp edge_fragment(_outgoing, label), do: "-[:#{label}]->"

  defp src_match(src_pkey) do
    Enum.map_join(src_pkey, " AND ", fn f ->
      f = f |> to_string() |> Migration.validate_identifier!()
      "a.#{f} = sid.#{f}"
    end)
  end

  defp src_return(src_pkey) do
    src_pkey
    |> Enum.with_index(1)
    |> Enum.map_join(", ", fn {f, i} ->
      f = f |> to_string() |> Migration.validate_identifier!()
      "a.#{f} AS s#{i}"
    end)
  end

  defp return_types(src_pkey) do
    Enum.map(1..length(src_pkey), fn i -> {String.to_atom("s#{i}"), :agtype} end) ++
      [{:b, :agtype}]
  end

  # --- result assembly (F3 map key + dedup + cardinality; unit-tested) ---

  @doc false
  def assemble_rows(rows, %{src_pkey: src_pkey, dest_pkey: dest_pkey, dest: dest} = spec, card) do
    {attr_map, attr_types} = dest_maps(dest)
    # Source-PK attribute types coerce the decoded scalar back to the record's
    # runtime shape (e.g. a date PK: ISO string -> %Date{}), so the F3 key ===
    # Map.take(record, src_pkey). Absent (unit test) -> identity coercion.
    src_types = Map.get(spec, :src_types, %{})
    n = length(src_pkey)

    grouped =
      Enum.reduce(rows, %{}, fn row, acc ->
        {src_cols, [b_col]} = Enum.split(row, n)

        src_key =
          Map.new(Enum.zip(src_pkey, src_cols), fn {atom, col} ->
            {atom, Cast.coerce_value(Agtype.decode(col), Map.get(src_types, atom))}
          end)

        b_record = decode_record(b_col, dest, attr_map, attr_types)
        Map.update(acc, src_key, [b_record], &[b_record | &1])
      end)

    grouped
    |> Enum.map(fn {k, recs} -> {k, dedup(Enum.reverse(recs), dest_pkey)} end)
    |> Enum.map(fn {k, recs} -> {k, cardinalize(recs, card)} end)
    |> Map.new()
  end

  defp dedup(records, dest_pkey) do
    {out, _seen} =
      Enum.reduce(records, {[], MapSet.new()}, fn r, {out, seen} ->
        key = Map.take(r, dest_pkey)
        if MapSet.member?(seen, key), do: {out, seen}, else: {[r | out], MapSet.put(seen, key)}
      end)

    Enum.reverse(out)
  end

  defp cardinalize(records, :one), do: List.first(records)
  defp cardinalize(records, _many), do: records

  defp decode_record(b_col, dest, attr_map, attr_types) do
    attrs = Cast.vertex_to_resource_attrs(Agtype.decode(b_col), attr_map, attr_types)
    struct(dest, attrs) |> Map.put(:__meta__, %Metadata{state: :loaded, schema: dest})
  end

  # dest may be a real Ash resource (use Info) or a plain struct in unit tests.
  # `Ash.Resource.Info.resource?/1` is the canonical discriminator (info.ex:330).
  defp dest_maps(dest) do
    if Ash.Resource.Info.resource?(dest) do
      {Info.attribute_map(dest), Info.attribute_types(dest)}
    else
      keys =
        dest |> struct() |> Map.from_struct() |> Map.keys() |> Enum.reject(&(&1 == :__meta__))

      {Map.new(keys, &{&1, to_string(&1)}), Map.new(keys, &{&1, :string})}
    end
  end

  # --- helpers ---

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp strategy(resource), do: Ash.Resource.Info.multitenancy_strategy(resource)

  # `row_count` is the raw pre-dedup rows returned by SQL.query — a genuine
  # fan-out signal because the emitted Cypher uses no SQL DISTINCT (UNION ALL for
  # the :attribute branches); `destination_count` is the Elixir-deduped/
  # cardinalized total (§5.4).
  defp stop_meta({:ok, map}, row_count, max_depth) do
    dests = map |> Map.values() |> Enum.map(&List.wrap/1) |> List.flatten()
    %{destination_count: length(dests), row_count: row_count, depth: max_depth, result: :ok}
  end

  defp stop_meta({:error, _}, _row_count, max_depth),
    do: %{destination_count: 0, row_count: 0, depth: max_depth, result: :error}
end
