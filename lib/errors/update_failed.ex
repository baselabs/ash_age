defmodule AshAge.Errors.UpdateFailed do
  @moduledoc """
  Error for failed update operations.
  """

  use Splode.Error, fields: [:resource, :reason], class: :invalid

  def message(%{resource: resource, reason: reason}) do
    "Update failed for #{inspect(resource)}: #{inspect_reason(reason)}"
  end

  # Structural guard: every call site pre-redacts its reason, but message/1 is
  # public — a future caller passing a raw driver error must not have its
  # DETAIL/message lines inspected into logs (AGENTS.md rule 5).
  defp inspect_reason(%Postgrex.Error{}), do: "database error (redacted)"
  defp inspect_reason(%{postgres: _}), do: "database error (redacted)"
  defp inspect_reason(reason), do: inspect(reason)
end
