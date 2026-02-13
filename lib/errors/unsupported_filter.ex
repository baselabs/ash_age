defmodule AshAge.Errors.UnsupportedFilter do
  @moduledoc """
  Error for unsupported filter operations.
  """

  use Splode.Error, fields: [:expression], class: :invalid

  def message(%{expression: expression}) do
    "Unsupported filter expression: #{inspect(expression)}"
  end
end
