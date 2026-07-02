defmodule AshAge.Edge do
  @moduledoc """
  Edge configuration for AGE relationships.
  """

  defstruct [:name, :label, :direction, :destination, properties: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          label: atom(),
          direction: :outgoing | :incoming | :both,
          destination: module(),
          properties: [atom()]
        }
end
