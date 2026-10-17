defmodule AshAge.Errors.QueryFailed do
  @moduledoc """
  Error for failed queries.
  """

  alias AshAge.Errors.Redaction

  use Splode.Error, fields: [:query, :reason], class: :invalid

  def message(%{query: query, reason: reason}) do
    "Query failed: #{Redaction.safe_inspect(query)} - #{Redaction.safe_inspect(reason)}"
  end
end
