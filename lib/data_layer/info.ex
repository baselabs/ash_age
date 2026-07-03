defmodule AshAge.DataLayer.Info do
  @moduledoc """
  Info functions for AGE data layer configuration.

  Reads all values dynamically from the resource's `age do ... end` DSL block
  via `Spark.Dsl.Extension`. No hard-coded defaults — the DSL schema enforces
  required options.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Extension

  @doc "Gets the graph name for a resource."
  def graph(resource), do: Extension.get_opt(resource, [:age], :graph)

  @doc "Gets the repo for a resource."
  def repo(resource), do: Extension.get_opt(resource, [:age], :repo)

  @doc "Gets the label for a resource."
  def label(resource) do
    Extension.get_opt(resource, [:age], :label) || default_label(resource)
  end

  @doc "Gets attributes to skip."
  def skip(resource), do: Extension.get_opt(resource, [:age], :skip, [])

  @doc "Gets the sensitive-classified attribute names (default [])."
  def sensitive(resource), do: Extension.get_opt(resource, [:age], :sensitive, [])

  @doc "Gets the tenant_graph MFA override for a resource, or nil."
  def tenant_graph(resource), do: Extension.get_opt(resource, [:age], :tenant_graph, nil)

  @doc "Gets the RLS GUC name for a resource, or nil (RLS not enabled)."
  def rls_guc(resource), do: Extension.get_opt(resource, [:age], :rls_guc, nil)

  @doc "Gets the configured edge entities for a resource."
  def edges(resource), do: Extension.get_entities(resource, [:age])

  @doc "Gets the attribute map for a resource (name → graph property name)."
  def attribute_map(resource) do
    skip_attrs = skip(resource)

    resource
    |> ResourceInfo.attributes()
    |> Enum.reject(fn attr -> attr.name in skip_attrs end)
    |> Map.new(fn attr -> {attr.name, Atom.to_string(attr.name)} end)
  end

  @doc """
  Gets the attribute type specs for a resource (name → `{type, constraints}`).

  Carries constraints so every wire path (`AshAge.Type.Cast.serialize_value/2`,
  `coerce_value/2`) resolves storage classes with the SAME inputs the
  verifiers and range/sort gates use (`Ash.Type.storage_type/2`) — a type
  whose storage class depends on constraints must never verify one way and
  encode another.
  """
  def attribute_types(resource) do
    resource
    |> ResourceInfo.attributes()
    |> Map.new(fn attr -> {attr.name, {attr.type, attr.constraints}} end)
  end

  defp default_label(resource) do
    resource
    |> Module.split()
    |> List.last()
  end
end
