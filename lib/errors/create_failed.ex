defmodule AshAge.Errors.CreateFailed do
  @moduledoc """
  Error for failed create operations.
  """

  alias AshAge.Errors.Redaction

  use Splode.Error, fields: [:resource, :reason], class: :invalid

  def message(%{resource: resource, reason: reason}) do
    "Create failed for #{inspect(resource)}: #{Redaction.safe_inspect(reason)}"
  end
end
