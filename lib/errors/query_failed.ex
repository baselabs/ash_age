defmodule AshAge.Errors.QueryFailed do
  @moduledoc """
  Error for failed queries.
  """

  use Splode.Error, fields: [:query, :reason], class: :invalid

  def message(%{query: query, reason: reason}) do
    "Query failed: #{inspect(query)} - #{inspect(reason)}"
  end
end
