defmodule AshAge.Type.Edge do
  @moduledoc """
  Edge type for AGE graph relationships.
  """

  defstruct [:id, :label, :start_id, :end_id, :properties]

  @type t :: %__MODULE__{
          id: integer(),
          label: String.t(),
          start_id: integer(),
          end_id: integer(),
          properties: map()
        }
end
