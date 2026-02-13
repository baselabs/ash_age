defmodule AshAge.Type.Cast do
  @moduledoc """
  Cast functions for AGE types.
  """

  alias AshAge.Type.Vertex

  @doc """
  Converts a vertex to resource attributes.
  """
  def vertex_to_resource_attrs(%Vertex{} = _vertex, _attribute_map, _attribute_types) do
    # Simplified implementation
    Map.new()
  end

  def vertex_to_resource_attrs(_other, _attribute_map, _attribute_types), do: Map.new()
end
