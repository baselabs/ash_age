defmodule AshAge.Type.Vertex do
  @moduledoc """
  Vertex type for AGE graph nodes.
  """

  defstruct [:id, :label, :properties]

  @type t :: %__MODULE__{
          id: String.t() | integer(),
          label: String.t(),
          properties: map()
        }
end
