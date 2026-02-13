defmodule AshAge.Errors.CreateFailed do
  @moduledoc """
  Error for failed create operations.
  """

  use Splode.Error, fields: [:resource, :reason], class: :invalid

  def message(%{resource: resource, reason: reason}) do
    "Create failed for #{inspect(resource)}: #{inspect(reason)}"
  end
end
