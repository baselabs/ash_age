defmodule AshAge.Errors.UpdateFailed do
  @moduledoc """
  Error for failed update operations.
  """

  use Splode.Error, fields: [:resource, :reason], class: :invalid

  def message(%{resource: resource, reason: reason}) do
    "Update failed for #{inspect(resource)}: #{inspect(reason)}"
  end
end
