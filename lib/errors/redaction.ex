defmodule AshAge.Errors.Redaction do
  @moduledoc false
  # The single structural-redaction home every error `message/1` shares
  # (AGENTS.md rule 5). Data-layer call sites pre-redact their reasons, but
  # the error structs are public: a future caller passing a raw driver error,
  # a wrapped tuple, or an encode failure must never have its DETAIL lines or
  # bytes inspected into logs. Structural shapes only — this never sees, and
  # therefore never echoes, a value it names.

  @doc "Inspect a reason for an error message, redacting every value-carrying shape structurally."
  def safe_inspect(%Postgrex.Error{}), do: "database error (redacted)"
  def safe_inspect(%{postgres: _}), do: "database error (redacted)"
  def safe_inspect(%Jason.EncodeError{}), do: "value not JSON-encodable (redacted)"

  # Wrapped shapes (a repo transaction's {:error, reason}, driver return tuples
  # of any arity, nested lists) — recurse element-wise.
  def safe_inspect(tuple) when is_tuple(tuple) do
    "{" <> Enum.map_join(Tuple.to_list(tuple), ", ", &safe_inspect/1) <> "}"
  end

  def safe_inspect(list) when is_list(list), do: inspect(Enum.map(list, &label/1))

  # Any other struct (DBConnection errors, driver exceptions): its message/
  # detail fields may carry values — keep only the structural name.
  def safe_inspect(%struct{}), do: "#{inspect(struct)} (redacted)"

  # Plain maps can nest params/values (e.g. a caller passing a query map) —
  # keep only the key names.
  def safe_inspect(map) when is_map(map),
    do: "map with keys #{inspect(Map.keys(map))} (values redacted)"

  # Primitives carry no nested value channel.
  def safe_inspect(primitive), do: inspect(primitive)

  defp label(%_{} = s), do: safe_inspect(s)
  defp label(other), do: safe_inspect(other)
end
