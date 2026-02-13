defmodule AshAge.Query.Filter do
  @moduledoc """
  Translates Ash.Filter into Cypher WHERE clauses.

  Only handles filter operations that AGE actually supports.
  Returns {:error, %UnsupportedFilter{}} for anything we can't push down.

  ## Supported operators:
  - eq, not_eq, gt, lt, gte, lte
  - in, is_nil
  - and, or, not

  ## NOT supported (returns error):
  - like, ilike
  - Aggregate subqueries
  - Exists subqueries
  """

  require Ash.Filter
  require Ash.Query

  alias AshAge.Errors.UnsupportedFilter
  alias AshAge.Query

  @doc "Translate an Ash filter expression into a Cypher WHERE fragment + parameters"
  @spec translate(term(), Query.t()) :: {:ok, Query.t(), String.t()} | {:error, term()}
  def translate(%Ash.Filter{expression: nil}, query) do
    {:ok, query, ""}
  end

  def translate(%Ash.Filter{expression: expression}, query) do
    do_translate(expression, query)
  end

  def translate(filter, query) do
    do_translate(filter, query)
  end

  # Boolean expressions
  defp do_translate(%Ash.Query.BooleanExpression{op: :and, left: l, right: r}, query) do
    with {:ok, query, left_clause} <- do_translate(l, query),
         {:ok, query, right_clause} <- do_translate(r, query) do
      {:ok, query, "(#{left_clause} AND #{right_clause})"}
    end
  end

  defp do_translate(%Ash.Query.BooleanExpression{op: :or, left: l, right: r}, query) do
    with {:ok, query, left_clause} <- do_translate(l, query),
         {:ok, query, right_clause} <- do_translate(r, query) do
      {:ok, query, "(#{left_clause} OR #{right_clause})"}
    end
  end

  defp do_translate(%Ash.Query.Not{expression: expr}, query) do
    with {:ok, query, clause} <- do_translate(expr, query) do
      {:ok, query, "NOT (#{clause})"}
    end
  end

  # Equality
  defp do_translate(
         %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value))
    {:ok, query, "n.#{attr.name} = #{param_ref}"}
  end

  # Not equal
  defp do_translate(
         %Ash.Query.Operator.NotEq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value))
    {:ok, query, "n.#{attr.name} <> #{param_ref}"}
  end

  # Greater than
  defp do_translate(
         %Ash.Query.Operator.GreaterThan{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value))
    {:ok, query, "n.#{attr.name} > #{param_ref}"}
  end

  # Less than
  defp do_translate(
         %Ash.Query.Operator.LessThan{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value))
    {:ok, query, "n.#{attr.name} < #{param_ref}"}
  end

  # Greater than or equal
  defp do_translate(
         %Ash.Query.Operator.GreaterThanOrEqual{
           left: %Ash.Query.Ref{attribute: attr},
           right: value
         },
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value))
    {:ok, query, "n.#{attr.name} >= #{param_ref}"}
  end

  # Less than or equal
  defp do_translate(
         %Ash.Query.Operator.LessThanOrEqual{
           left: %Ash.Query.Ref{attribute: attr},
           right: value
         },
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value))
    {:ok, query, "n.#{attr.name} <= #{param_ref}"}
  end

  # IN operator
  defp do_translate(
         %Ash.Query.Operator.In{left: %Ash.Query.Ref{attribute: attr}, right: values},
         query
       )
       when is_list(values) do
    {query, param_ref} = Query.add_param(query, Enum.map(values, &cast_value/1))
    {:ok, query, "n.#{attr.name} IN #{param_ref}"}
  end

  # IS NULL / IS NOT NULL
  defp do_translate(
         %Ash.Query.Operator.IsNil{left: %Ash.Query.Ref{attribute: attr}, right: true},
         query
       ) do
    {:ok, query, "n.#{attr.name} IS NULL"}
  end

  defp do_translate(
         %Ash.Query.Operator.IsNil{left: %Ash.Query.Ref{attribute: attr}, right: false},
         query
       ) do
    {:ok, query, "n.#{attr.name} IS NOT NULL"}
  end

  # Catch-all: unsupported filter
  defp do_translate(expr, _query) do
    {:error, UnsupportedFilter.exception(expression: inspect(expr))}
  end

  # Value casting for AGE compatibility
  defp cast_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp cast_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp cast_value(%Date{} = d), do: Date.to_iso8601(d)
  defp cast_value(value), do: value
end
