defmodule AshAge.Changes.EdgeCypher do
  @moduledoc false
  # Shared, security-critical helpers for the edge change modules
  # (`AshAge.Changes.CreateEdge` / `DestroyEdge`). Both build parameterized edge
  # Cypher from the same endpoint identification, identifier validation, and
  # tenant-scoping rules; keeping that logic in ONE place prevents the two
  # modules' tenant/injection clauses from silently diverging (a divergence in
  # `tenant_where/1` would be a cross-tenant write hole). Same dependency level
  # as its callers (above the data layer): imports `Info` (L3) / `Migration` (L0).

  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer.Info
  alias AshAge.Migration
  alias AshAge.Type.Cast

  @doc false
  # Wraps Parameterized.safe_build (the one home of the encode-failure rescue
  # classifier) so a non-JSON-encodable property/param fails closed as a
  # value-free tuple instead of a raise whose message embeds the bytes
  # (AGENTS.md rule 5), keeping the edge paths' string-reason error contract.
  def safe_build(graph, cypher, params, return_types) do
    case Parameterized.safe_build(graph, cypher, params, return_types) do
      {:ok, built} ->
        {:ok, built}

      {:error, :params_not_json_encodable} ->
        {:error, "edge parameters not JSON-encodable (raw binary in a non-binary-typed value?)"}
    end
  end

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
  # Destination endpoint values serialized by the DESTINATION RESOURCE's PK
  # attribute type — the `to:` argument's declared type does not govern the
  # stored wire form (spec C6). Resolves the PK and type spec ONCE for the
  # whole list (the edge write loops run once per destination; per-id
  # re-introspection was the S7-closeout O1 advisory). Single-attribute PK is
  # enforced by destination_pk! at the build site, so this match cannot fail.
  # Shared by CreateEdge and DestroyEdge for the same anti-divergence reason
  # as source_key/2.
  def serialize_destination_ids(destination, dest_ids) do
    [dest_pk_attr] = Ash.Resource.Info.primary_key(destination)
    spec = Map.get(Info.attribute_types(destination), dest_pk_attr)
    Enum.map(dest_ids, &Cast.serialize_value(&1, spec))
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
        {["a.`#{field}` = $#{key}" | clauses], Map.put(params, key, value)}
      end)

    {clauses |> Enum.reverse() |> Enum.join(" AND "), params}
  end

  @doc false
  # For an `:attribute`-multitenant source, the
  # `{src_attr, dest_attr, src_value, dest_value}` spec scoping BOTH endpoints
  # by the tenant discriminator; `nil` otherwise. Each endpoint's VALUE is
  # parsed by ITS OWN resource's `parse_attribute` (the source's parse fn for
  # `a`, the destination's for `b`) — a single shared value would bind a
  # source-parsed string against the destination's discriminator and, under
  # differing parse fns, match a DIFFERENT tenant's destination rows.
  def tenant_spec(resource, edge, changeset) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
      dest = edge.destination
      dest_attr = Ash.Resource.Info.multitenancy_attribute(dest)

      {Ash.Resource.Info.multitenancy_attribute(resource), dest_attr,
       parse_tenant(resource, changeset.to_tenant),
       if(dest_attr, do: parse_tenant(dest, changeset.to_tenant))}
    else
      nil
    end
  end

  # Vertex-path parity (scope_to_tenant applies the same MFA): the scoping
  # VALUE is the resource's parsed tenant, not the raw `to_tenant`. A nil
  # tenant (a `global? true` / tenantless action) is NOT parsed — Ash itself
  # skips parsing then, and a custom parse fn would crash on nil. A nil value
  # matches nothing (fail-closed-empty), same envelope as the vertex path.
  defp parse_tenant(_resource, nil), do: nil

  defp parse_tenant(resource, tenant) do
    {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(resource)
    apply(m, f, [tenant | a])
  end

  @doc false
  # Builds the tenant WHERE fragment. A non-multitenant destination (nil
  # dest_attr) takes no destination clause. Returns `{clause, params}`.
  def tenant_where(nil), do: {"", %{}}

  def tenant_where({src_attr, dest_attr, src_value, dest_value}) do
    src_attr = src_attr |> to_string() |> Migration.validate_identifier!()
    dest = if dest_attr, do: dest_attr |> to_string() |> Migration.validate_identifier!()

    # Endpoint refs are backtick-quoted: a tenant discriminator named with a
    # Cypher keyword (`count`, `label`) must not emit a bare ref (AGE syntax
    # error), same discipline as Filter.prop_ref.
    clause =
      " AND a.`#{src_attr}` = $tenant" <>
        if(dest, do: " AND b.`#{dest}` = $dst_tenant", else: "")

    {clause, %{"tenant" => src_value, "dst_tenant" => dest_value}}
  end
end
