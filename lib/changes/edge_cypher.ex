defmodule AshAge.Changes.EdgeCypher do
  @moduledoc false
  # Shared, security-critical helpers for the edge change modules
  # (`AshAge.Changes.CreateEdge` / `DestroyEdge`). Both build parameterized edge
  # Cypher from the same endpoint identification, identifier validation, and
  # tenant-scoping rules; keeping that logic in ONE place prevents the two
  # modules' tenant/injection clauses from silently diverging (a divergence in
  # `tenant_where/1` would be a cross-tenant write hole). Same dependency level
  # as its callers (above the data layer): imports `Info` (L3) / `Migration` (L0).

  alias AshAge.DataLayer.Info
  alias AshAge.Migration
  alias AshAge.Type.Cast

  @doc false
  # Resolves the named edge on the resource, raising if it isn't declared.
  def fetch_edge!(resource, name) do
    case Enum.find(Info.edges(resource), &(&1.name == name)) do
      %AshAge.Edge{} = edge -> edge
      nil -> raise ArgumentError, "no `edge #{inspect(name)}` declared on #{inspect(resource)}"
    end
  end

  @doc false
  # The resource's AGE vertex label, validated as an AGE identifier.
  def validated_label(resource), do: resource |> Info.label() |> Migration.validate_identifier!()

  @doc false
  # The destination's single-attribute primary key name, validated. Edge
  # destinations must have a single-attribute PK.
  def destination_pk!(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [single] -> single |> to_string() |> Migration.validate_identifier!()
      _ -> raise ArgumentError, "edge destinations must have a single-attribute primary key"
    end
  end

  @doc false
  # A map of source PK field (string) => value, read from the PERSISTED record
  # (its original identity), not the pending changeset. Values are serialized by
  # the SOURCE RESOURCE's attribute types (binary-storage → tagged) so the WHERE
  # matches the stored wire form.
  def source_key(resource, record) do
    types = Info.attribute_types(resource)

    resource
    |> Ash.Resource.Info.primary_key()
    |> Map.new(fn f ->
      {to_string(f), Cast.serialize_value(Map.get(record, f), Map.get(types, f))}
    end)
  end

  @doc false
  # Builds the source WHERE clause (`a.<pk> = $src_<pk>`), each field validated
  # and each value bound as a `$param`. Returns `{clause, params}`.
  def source_where(src_key) do
    {clauses, params} =
      Enum.reduce(src_key, {[], %{}}, fn {field, value}, {clauses, params} ->
        field = Migration.validate_identifier!(field)
        key = "src_#{field}"
        {["a.#{field} = $#{key}" | clauses], Map.put(params, key, value)}
      end)

    {clauses |> Enum.reverse() |> Enum.join(" AND "), params}
  end

  @doc false
  # For an `:attribute`-multitenant source, the `{src_attr, dest_attr, value}`
  # spec that scopes BOTH endpoints by the tenant discriminator; `nil` otherwise.
  def tenant_spec(resource, edge, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
      {Ash.Resource.Info.multitenancy_attribute(resource),
       Ash.Resource.Info.multitenancy_attribute(edge.destination), changeset.to_tenant}
    else
      nil
    end
  end

  @doc false
  # Builds the tenant WHERE fragment. A non-multitenant destination (nil
  # dest_attr) takes no destination clause. Returns `{clause, params}`.
  def tenant_where(nil), do: {"", %{}}

  def tenant_where({src_attr, dest_attr, value}) do
    src_attr = src_attr |> to_string() |> Migration.validate_identifier!()
    dest = if dest_attr, do: dest_attr |> to_string() |> Migration.validate_identifier!()

    clause =
      " AND a.#{src_attr} = $tenant" <> if(dest, do: " AND b.#{dest} = $tenant", else: "")

    {clause, %{"tenant" => value}}
  end
end
