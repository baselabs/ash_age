defmodule AshAge.Errors.UnsupportedExpression do
  @moduledoc """
  Error for an `Ash.Expr` node the Cypher translator cannot map to AGE.

  Carries only structural information — a short, value-free label for the
  rejected node (`:fragment`, `:now`, `{:ref, [:rel, :name]}`, etc.) and a
  reason string. The expression's values are deliberately never captured, so
  neither the message nor any log line built from it can leak PII/secrets
  (AGENTS.md Critical Security Rule 5 — the same discipline as
  `AshAge.Errors.UnsupportedFilter`).
  """

  use Splode.Error, fields: [:node, :reason], class: :invalid

  def message(%{node: node, reason: reason}) do
    "Unsupported Ash.Expr for Cypher translation: #{inspect(node)} — #{reason}"
  end
end
