defmodule AshAge.Errors.UnsupportedFilter do
  @moduledoc """
  Error for unsupported filter operations.

  Carries only structural information — the operator/function module and the
  referenced field name. The filtered value is deliberately never captured, so
  neither the message nor any log line built from it can leak PII/secrets.
  """

  use Splode.Error, fields: [:operator, :field], class: :invalid

  def message(%{operator: operator, field: nil}) do
    "Unsupported filter operator: #{inspect(operator)}"
  end

  def message(%{operator: operator, field: field}) do
    "Unsupported filter operator: #{inspect(operator)} on field #{inspect(field)}"
  end
end
