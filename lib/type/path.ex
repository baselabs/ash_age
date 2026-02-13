defmodule AshAge.Type.Path do
  @moduledoc """
  Path type for AGE graph traversal results.
  """

  defstruct [:vertices, :edges]

  @type t :: %__MODULE__{
          vertices: list(AshAge.Type.Vertex.t()),
          edges: list(term())
        }
end
