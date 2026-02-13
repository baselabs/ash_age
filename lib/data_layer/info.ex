defmodule AshAge.DataLayer.Info do
  @moduledoc """
  Info functions for AGE data layer configuration.
  """

  @doc "Gets the graph name for a resource."
  def graph(_resource), do: :knowledge_graph

  @doc "Gets the label for a resource."
  def label(_resource), do: "Entity"

  @doc "Gets the repo for a resource."
  def repo(_resource), do: GptCore.Repo

  @doc "Gets the attribute map for a resource."
  def attribute_map(_resource), do: %{}

  @doc "Gets the attribute types for a resource."
  def attribute_types(_resource), do: %{}

  @doc "Gets attributes to skip."
  def skip(_resource), do: []
end
