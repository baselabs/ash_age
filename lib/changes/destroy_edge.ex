defmodule AshAge.Changes.DestroyEdge do
  @moduledoc """
  Ash change that removes a graph edge from the action's record to a destination
  record named by an argument, after the vertex write, inside the action's
  transaction.

      change {AshAge.Changes.DestroyEdge, edge: :author, to: :author_id}

  `edge:` names an `edge` entry in the resource's `age do ... end` block. `to:`
  names an action argument holding the destination primary key (or a list of
  keys -> N deletes). An edge that matched nothing (already gone or out of the
  source's graph/tenant scope) returns `Ash.Error.Changes.StaleRecord` so Ash
  rolls the vertex back; DB errors are redacted.

  A nil or empty `to:` argument removes NO edge and the action still succeeds
  (the removal is optional). Make `to:` required at the call site to force one.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidRelationship
  alias Ash.Error.Changes.StaleRecord
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer
  alias AshAge.DataLayer.Info
  alias AshAge.Migration
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
    edge = fetch_edge!(resource, Keyword.fetch!(opts, :edge))
    dest_ids = List.wrap(Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :to)))

    case DataLayer.write_graph(resource, changeset) do
      {:ok, graph} ->
        tenant = tenant_spec(resource, edge, changeset)
        src_key = source_key(resource, record)
        destroy_all(record, dest_ids, resource, edge, graph, src_key, tenant)

      {:error, :tenant_required} ->
        {:error,
         InvalidRelationship.exception(relationship: edge.name, message: "tenant required")}
    end
  end

  # Removes one edge per destination id, halting (and returning the error so Ash
  # rolls the vertex back) on the first failed or 0-row delete.
  defp destroy_all(record, dest_ids, resource, edge, graph, src_key, tenant) do
    Enum.reduce_while(dest_ids, {:ok, record}, fn dest_id, {:ok, rec} ->
      case destroy_one(resource, edge, graph, src_key, dest_id, tenant) do
        {:ok, _} -> {:cont, {:ok, rec}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp destroy_one(resource, edge, graph, src_key, dest_id, tenant) do
    {cypher, params} = build_destroy(resource, edge, src_key, dest_id, tenant)
    {sql, pg_params} = Parameterized.build(graph, cypher, params, [{:r, :agtype}])

    case SQL.query(Info.repo(resource), sql, pg_params) do
      {:ok, %{num_rows: n}} when n >= 1 ->
        {:ok, :destroyed}

      {:ok, %{num_rows: 0}} ->
        {:error,
         StaleRecord.exception(resource: resource, filter: Map.put(src_key, "dst", dest_id))}

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
  # (string) => value. `tenant` is nil or {src_attr, dest_attr, value}. Sets no
  # properties (a delete): the RETURN column is `r`, the deleted edge.
  def build_destroy(resource, edge, src_key, dest_id, tenant) do
    src_label = validated_label(resource)
    dest_label = validated_label(edge.destination)
    edge_label = Migration.validate_identifier!(edge.label)
    dest_pk = destination_pk!(edge.destination)

    {src_where, src_params} = source_where(src_key)
    {tenant_where, tenant_params} = tenant_where(tenant)

    pattern =
      case edge.direction do
        :incoming -> "(a:#{src_label})<-[r:#{edge_label}]-(b:#{dest_label})"
        _ -> "(a:#{src_label})-[r:#{edge_label}]->(b:#{dest_label})"
      end

    cypher =
      "MATCH #{pattern} WHERE #{src_where} AND b.#{dest_pk} = $dst#{tenant_where} DELETE r RETURN r"

    {cypher, src_params |> Map.put("dst", dest_id) |> Map.merge(tenant_params)}
  end

  # --- helpers (duplicated byte-identical from AshAge.Changes.CreateEdge) ---

  defp fetch_edge!(resource, name) do
    case Enum.find(Info.edges(resource), &(&1.name == name)) do
      %AshAge.Edge{} = edge -> edge
      nil -> raise ArgumentError, "no `edge #{inspect(name)}` declared on #{inspect(resource)}"
    end
  end

  defp validated_label(resource), do: resource |> Info.label() |> Migration.validate_identifier!()

  defp destination_pk!(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [single] -> single |> to_string() |> Migration.validate_identifier!()
      _ -> raise ArgumentError, "edge destinations must have a single-attribute primary key"
    end
  end

  defp source_key(resource, record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Map.new(fn f -> {to_string(f), Map.get(record, f)} end)
  end

  defp source_where(src_key) do
    {clauses, params} =
      Enum.reduce(src_key, {[], %{}}, fn {field, value}, {clauses, params} ->
        field = Migration.validate_identifier!(field)
        key = "src_#{field}"
        {["a.#{field} = $#{key}" | clauses], Map.put(params, key, value)}
      end)

    {clauses |> Enum.reverse() |> Enum.join(" AND "), params}
  end

  defp tenant_spec(resource, edge, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
      {Ash.Resource.Info.multitenancy_attribute(resource),
       Ash.Resource.Info.multitenancy_attribute(edge.destination), changeset.to_tenant}
    else
      nil
    end
  end

  defp tenant_where(nil), do: {"", %{}}

  defp tenant_where({src_attr, dest_attr, value}) do
    src_attr = src_attr |> to_string() |> Migration.validate_identifier!()
    dest = if dest_attr, do: dest_attr |> to_string() |> Migration.validate_identifier!()

    clause =
      " AND a.#{src_attr} = $tenant" <> if(dest, do: " AND b.#{dest} = $tenant", else: "")

    {clause, %{"tenant" => value}}
  end
end
