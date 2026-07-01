defmodule AshAge.Changes.CreateEdge do
  @moduledoc """
  Ash change that persists a graph edge from the action's record to a
  destination record named by an argument, after the vertex write, inside the
  action's transaction.

      change {AshAge.Changes.CreateEdge, edge: :author, to: :author_id}

  `edge:` names an `edge` entry in the resource's `age do ... end` block. `to:`
  names an action argument holding the destination primary key (or a list of
  keys -> N edges). Edge property values come from same-named action arguments
  (per the edge's `properties [...]`). A failed or 0-row edge write returns
  `{:error, _}` so Ash rolls the vertex back; DB errors are redacted.

  Each edge `property` MUST correspond to a same-named DECLARED action argument:
  that argument's declared type governs serialization exactly as a vertex
  attribute's type does (binary -> `$age64$`-tagged, datetime/date -> ISO8601).
  A value set on an UNDECLARED argument has no type and is stored untagged, so
  only declared property arguments are supported.

  A nil or empty `to:` argument writes NO edge and the action still succeeds
  (the edge is optional). Make `to:` required at the call site to force one.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidRelationship
  alias AshAge.Changes.EdgeCypher
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer
  alias AshAge.DataLayer.Info
  alias AshAge.Migration
  alias AshAge.Telemetry
  alias Ecto.Adapters.SQL

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      run(changeset, record, opts)
    end)
  end

  @doc false
  def run(changeset, record, opts) do
    resource = changeset.resource
    start = %{resource: resource, multitenancy: Ash.Resource.Info.multitenancy_strategy(resource)}

    Telemetry.span(:create_edge, start, fn ->
      edge = EdgeCypher.fetch_edge!(resource, Keyword.fetch!(opts, :edge))
      dest_ids = destination_ids(changeset, opts)
      props = edge_properties(changeset, edge)

      result =
        case DataLayer.write_graph(resource, changeset) do
          {:ok, graph} ->
            tenant = EdgeCypher.tenant_spec(resource, edge, changeset)
            src_key = EdgeCypher.source_key(resource, record)
            create_all(record, dest_ids, resource, edge, graph, src_key, props, tenant)

          {:error, :tenant_required} ->
            {:error,
             InvalidRelationship.exception(relationship: edge.name, message: "tenant required")}
        end

      {result,
       %{
         destination_count: length(dest_ids),
         direction: edge.direction,
         properties?: map_size(props) > 0,
         tenant?: not is_nil(changeset.to_tenant),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  # Writes one edge per destination id, halting (and returning the error so Ash
  # rolls the vertex back) on the first failed or 0-row write.
  defp create_all(record, dest_ids, resource, edge, graph, src_key, props, tenant) do
    Enum.reduce_while(dest_ids, {:ok, record}, fn dest_id, {:ok, rec} ->
      case create_one(resource, edge, graph, src_key, dest_id, props, tenant) do
        {:ok, _} -> {:cont, {:ok, rec}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp create_one(resource, edge, graph, src_key, dest_id, props, tenant) do
    {cypher, params} = build_create(resource, edge, src_key, dest_id, props, tenant)
    {sql, pg_params} = Parameterized.build(graph, cypher, params, [{:e, :agtype}])

    case SQL.query(Info.repo(resource), sql, pg_params) do
      {:ok, %{num_rows: n}} when n >= 1 ->
        {:ok, :created}

      {:ok, %{num_rows: 0}} ->
        {:error,
         InvalidRelationship.exception(
           relationship: edge.name,
           message: "destination not found in the source's graph/tenant scope"
         )}

      {:error, error} ->
        {:error,
         InvalidRelationship.exception(
           relationship: edge.name,
           message: DataLayer.redact_db_error(error)
         )}
    end
  end

  @doc false
  # Pure cypher builder -- unit-tested. `src_key` is a map of source PK field
  # (string) => value. `tenant` is nil or {src_attr, dest_attr, value}.
  def build_create(resource, edge, src_key, dest_id, props, tenant) do
    src_label = EdgeCypher.validated_label(resource)
    dest_label = EdgeCypher.validated_label(edge.destination)
    edge_label = Migration.validate_identifier!(edge.label)
    dest_pk = EdgeCypher.destination_pk!(edge.destination)

    {src_where, src_params} = EdgeCypher.source_where(src_key)
    dest_where = "b.#{dest_pk} = $dst"
    {tenant_where, tenant_params} = EdgeCypher.tenant_where(tenant)
    {prop_set, prop_params} = property_set(props)

    arrow =
      case edge.direction do
        :incoming -> "(b)-[e:#{edge_label}]->(a)"
        _ -> "(a)-[e:#{edge_label}]->(b)"
      end

    cypher =
      "MATCH (a:#{src_label}), (b:#{dest_label}) " <>
        "WHERE #{src_where} AND #{dest_where}#{tenant_where} " <>
        "CREATE #{arrow}#{prop_set} RETURN e"

    params =
      src_params
      |> Map.put("dst", dest_id)
      |> Map.merge(tenant_params)
      |> Map.merge(prop_params)

    {cypher, params}
  end

  # --- helpers ---

  @doc false
  # Pure fn of `(changeset, opts)` -- unit-tested. Resolves the destination PK(s)
  # from the `to:` argument into a list: a single key -> one edge, a list -> N
  # edges, and a nil/unsupplied argument -> `[]` (no edge written, the action
  # still succeeds -- the edge is optional).
  def destination_ids(changeset, opts) do
    List.wrap(Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :to)))
  end

  @doc false
  # Pure fn of `(changeset, edge)` -- unit-tested. Collects each edge property's
  # value from the same-named action argument, rejects unset (nil) properties (so
  # an optional property that wasn't supplied is NOT written as an explicit null,
  # matching single-create vertex sparse semantics), and routes every value
  # through `DataLayer.serialize_value/2` by its declared argument type -- so a
  # `:binary` property is `$age64$`-tagged and a datetime/date becomes ISO8601,
  # byte-identical in fidelity to how vertex attributes are stored.
  def edge_properties(changeset, edge) do
    arg_types = argument_types(changeset)

    edge.properties
    |> Enum.map(fn key -> {key, Ash.Changeset.get_argument(changeset, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} ->
      {key, DataLayer.serialize_value(value, Map.get(arg_types, key))}
    end)
  end

  defp argument_types(%{action: %{arguments: arguments}}) when is_list(arguments) do
    Map.new(arguments, fn %{name: name, type: type} -> {name, type} end)
  end

  defp argument_types(_changeset), do: %{}

  defp property_set(props) when map_size(props) == 0, do: {"", %{}}

  defp property_set(props) do
    {clauses, params} =
      Enum.reduce(props, {[], %{}}, fn {key, value}, {clauses, params} ->
        key = key |> to_string() |> Migration.validate_identifier!()
        pkey = "prop_#{key}"
        {["e.#{key} = $#{pkey}" | clauses], Map.put(params, pkey, value)}
      end)

    {" SET " <> (clauses |> Enum.reverse() |> Enum.join(", ")), params}
  end
end
