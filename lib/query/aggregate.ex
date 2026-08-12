defmodule AshAge.Query.Aggregate do
  @moduledoc """
  Translates an `Ash.Query.Aggregate.t()` (no relationship path) into a Cypher
  `RETURN` expression over the matched vertices.

  AGE ships the standard Cypher aggregate functions (`count`, `sum`, `avg`, `min`,
  `max`); `exists` is expressed as `count(n)` and reduced to a boolean in Elixir,
  avoiding any dependency on AGE `EXISTS {}` syntax. Only the field NAME is
  interpolated — validated as an AGE identifier — never a value.
  """

  alias AshAge.Migration

  @doc """
  Returns the Cypher `RETURN` expression for `{kind, field}`.

  `field` is required for `sum`/`avg`/`min`/`max` and for `count` with `uniq?`.
  `count`/`exists` over vertices need no field.
  """
  @spec expr({atom, atom | nil, keyword}) :: String.t()
  def expr({kind, field, opts}) do
    uniq? = Keyword.get(opts, :uniq?, false)

    # A `case` on the {kind, field, uniq?} tuple (not a `cond` of boolean
    # predicates): pattern matches are not cyclomatic decision points, so this
    # reads as a dispatch table AND stays well under credo's complexity ceiling.
    # Pattern ORDER fixes the nil-field clause-order bug (specific patterns before
    # the field-binding catch-alls).
    case {kind, field, uniq?} do
      # exists is reduced to a boolean from the raw count in Elixir
      # (decode_value/2), so the Cypher returns the count itself.
      {:exists, _, _} ->
        "count(n)"

      {:count, nil, false} ->
        "count(n)"

      {:count, nil, true} ->
        raise ArgumentError, "AshAge count with uniq?: true requires a field to DISTINCT over"

      {:count, field, false} ->
        "count(n.#{validate_field!(field)})"

      {:count, field, true} ->
        "count(DISTINCT n.#{validate_field!(field)})"

      {kind, nil, _uniq?} when kind in [:sum, :avg, :min, :max] ->
        raise ArgumentError,
              "AshAge aggregate #{kind} requires a field; got nil " <>
                "(the aggregate was built without a :field)"

      {kind, _field, true} when kind in [:sum, :avg, :min, :max] ->
        raise ArgumentError,
              "AshAge does not support uniq?: true on #{kind} aggregates " <>
                "(AGE Cypher has no DISTINCT form for these)"

      {kind, field, false} when kind in [:sum, :avg, :min, :max] ->
        "#{kind}(n.#{validate_field!(field)})"
    end
  end

  defp validate_field!(field), do: Migration.validate_identifier!(field)

  @doc """
  Reduces a decoded agtype scalar to the value Ash expects for the aggregate kind.

  `exists` -> boolean (raw count > 0); every other kind -> the decoded value as-is
  (count -> integer, sum/avg -> number, min/max -> the value).
  """
  @spec decode_value(atom, term) :: term
  def decode_value(:exists, count) when is_number(count), do: count > 0
  def decode_value(:exists, _), do: false
  def decode_value(_kind, value), do: value
end
