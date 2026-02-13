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

  @doc "Gets the attribute types for a resource (name → Ash type)."
  def attribute_types(resource) do
    resource
    |> ResourceInfo.attributes()
    |> Map.new(fn attr -> {attr.name, attr.type} end)
  end

  defp default_label(resource) do
    resource
    |> Module.split()
    |> List.last()
  end
end
