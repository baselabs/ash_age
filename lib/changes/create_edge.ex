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
  Exception: the sensitive-property guard (runtime half of ValidateSensitive
  R4) fails the action even with an empty `to:` — the misdeclaration (a
  classified datum handed to a plaintext/undeclared argument) exists
  regardless of whether an edge would be written, matching the compile half's
  declaration-level semantics.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidRelationship
  alias AshAge.Changes.EdgeCypher
  alias AshAge.DataLayer
  alias AshAge.DataLayer.Info
  alias AshAge.Migration
  alias AshAge.Telemetry
  alias AshAge.Type.Cast
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

      {result, properties?} =
        case edge_properties(changeset, edge) do
          {:ok, props} ->
            {write_edges(changeset, record, resource, edge, dest_ids, props), map_size(props) > 0}

          {:error, key} ->
            {sensitive_property_error(edge, key), false}
        end

      {result,
       %{
         destination_count: length(dest_ids),
         direction: edge.direction,
         properties?: properties?,
         tenant?: not is_nil(changeset.to_tenant),
         result: Telemetry.result_tag(result)
       }}
    end)
  end

  defp write_edges(changeset, record, resource, edge, dest_ids, props) do
    case DataLayer.write_graph(resource, changeset) do
      {:ok, graph} ->
        tenant = EdgeCypher.tenant_spec(resource, edge, changeset)
        src_key = EdgeCypher.source_key(resource, record)
        dest_ids = EdgeCypher.serialize_destination_ids(edge.destination, dest_ids)
        create_all(record, dest_ids, resource, edge, graph, src_key, props, tenant)

      {:error, :tenant_required} ->
        {:error,
         InvalidRelationship.exception(relationship: edge.name, message: "tenant required")}
    end
  end

  # Value-free by construction: names the KEY only, never the value.
  defp sensitive_property_error(edge, key) do
    {:error,
     InvalidRelationship.exception(
       relationship: edge.name,
       message:
         "sensitive property #{inspect(key)} requires a binary-storage-typed " <>
           "declared action argument (value withheld)"
     )}
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

    case EdgeCypher.safe_build(graph, cypher, params, [{:e, :agtype}]) do
      {:error, message} ->
        {:error, InvalidRelationship.exception(relationship: edge.name, message: message)}

      {:ok, {sql, pg_params}} ->
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
  end

  @doc false
  # Pure cypher builder -- unit-tested. `src_key` is a map of source PK field
  # (string) => value. `tenant` is nil or {src_attr, dest_attr, value}.
  def build_create(resource, edge, src_key, dest_id, props, tenant) do
    src_label = EdgeCypher.validated_label(resource)
    dest_label = EdgeCypher.validated_label(edge.destination)
    edge_label = Migration.validate_identifier!(edge.label)
    dest_pk = EdgeCypher.destination_pk!(edge.destination)

    # PRECONDITION: dest_id is already serialized to the stored wire form
    # (EdgeCypher.serialize_destination_ids/2, hoisted out of the per-dest loop).

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
  # through `Cast.serialize_value/2` by its DECLARED argument type -- so a
  # `:binary` property is `$age64$`-tagged and a datetime/date becomes ISO8601,
  # byte-identical in fidelity to how vertex attributes are stored. Returns
  # `{:error, key}` (fail closed) when a key classified `sensitive` on the
  # source resource has no binary-storage-typed declared argument backing it --
  # an undeclared (`set_argument`-injected) or plaintext argument would
  # otherwise store the classified datum untagged on the edge. This is the
  # runtime half of ValidateSensitive R4.
  def edge_properties(changeset, edge) do
    arg_types = argument_types(changeset)
    sensitive = Info.sensitive(changeset.resource)

    edge.properties
    |> Enum.map(fn key -> {key, Ash.Changeset.get_argument(changeset, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      # {type, constraints} spec — the guard and the encoder resolve the
      # storage class with the SAME inputs the compile-time verifier (R4)
      # uses, so a declared argument can never verify one way and store
      # another. An undeclared (set_argument-injected) key has no spec:
      # {nil, []} → binary_storage? false → fail-closed halt.
      {type, constraints} = Map.get(arg_types, key, {nil, []})

      if key in sensitive and not Cast.binary_storage?(type, constraints) do
        {:halt, {:error, key}}
      else
        {:cont, {:ok, Map.put(acc, key, Cast.serialize_value(value, {type, constraints}))}}
      end
    end)
  end

  defp argument_types(%{action: %{arguments: arguments}}) when is_list(arguments) do
    Map.new(arguments, fn %{name: name, type: type} = arg ->
      {name, {type, Map.get(arg, :constraints) || []}}
    end)
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
