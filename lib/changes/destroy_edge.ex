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
  alias AshAge.Changes.EdgeCypher
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

    Telemetry.span(:destroy_edge, start, fn ->
      edge = EdgeCypher.fetch_edge!(resource, Keyword.fetch!(opts, :edge))
      dest_ids = List.wrap(Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :to)))

      result =
        case DataLayer.write_graph(resource, changeset) do
          {:ok, graph} ->
            tenant = EdgeCypher.tenant_spec(resource, edge, changeset)
            src_key = EdgeCypher.source_key(resource, record)
            destroy_all(record, dest_ids, resource, edge, graph, src_key, tenant)

          {:error, :tenant_required} ->
            {:error,
             InvalidRelationship.exception(relationship: edge.name, message: "tenant required")}
        end

      {result,
       %{
         destination_count: length(dest_ids),
         direction: edge.direction,
         tenant?: not is_nil(changeset.to_tenant),
         result: Telemetry.result_tag(result)
       }}
    end)
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

    case EdgeCypher.safe_build(graph, cypher, params, [{:r, :agtype}]) do
      {:error, message} ->
        {:error, InvalidRelationship.exception(relationship: edge.name, message: message)}

      {:ok, {sql, pg_params}} ->
        case SQL.query(Info.repo(resource), sql, pg_params) do
          {:ok, %{num_rows: n}} when n >= 1 ->
            {:ok, :destroyed}

          {:ok, %{num_rows: 0}} ->
            {:error,
             StaleRecord.exception(
               resource: resource,
               filter: DataLayer.redacted_filter(Map.put(src_key, "dst", dest_id))
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
  # (string) => value. `tenant` is nil or {src_attr, dest_attr, value}. Sets no
  # properties (a delete): the RETURN column is `r`, the deleted edge.
  def build_destroy(resource, edge, src_key, dest_id, tenant) do
    src_label = EdgeCypher.validated_label(resource)
    dest_label = EdgeCypher.validated_label(edge.destination)
    edge_label = Migration.validate_identifier!(edge.label)
    dest_pk = EdgeCypher.destination_pk!(edge.destination)

    dest_id = EdgeCypher.destination_id(edge.destination, dest_id)

    {src_where, src_params} = EdgeCypher.source_where(src_key)
    {tenant_where, tenant_params} = EdgeCypher.tenant_where(tenant)

    pattern =
      case edge.direction do
        :incoming -> "(a:#{src_label})<-[r:#{edge_label}]-(b:#{dest_label})"
        _ -> "(a:#{src_label})-[r:#{edge_label}]->(b:#{dest_label})"
      end

    cypher =
      "MATCH #{pattern} WHERE #{src_where} AND b.#{dest_pk} = $dst#{tenant_where} DELETE r RETURN r"

    {cypher, src_params |> Map.put("dst", dest_id) |> Map.merge(tenant_params)}
  end
end
