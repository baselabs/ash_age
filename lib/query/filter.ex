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
  alias AshAge.Type.Cast

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

  # Attribute-to-attribute comparisons (`attr1 == attr2`) carry a Ref on the
  # RIGHT side — there is no bindable value. Without this clause the Ref struct
  # itself would be bound as a param and fail downstream as "params not
  # JSON-encodable" (fail-closed, but a misleading error class). Reject it
  # structurally as unsupported instead. Must precede every operator clause.
  defp do_translate(%mod{left: %Ash.Query.Ref{}, right: %Ash.Query.Ref{}} = expr, _query)
       when mod in [
              Ash.Query.Operator.Eq,
              Ash.Query.Operator.NotEq,
              Ash.Query.Operator.In,
              Ash.Query.Operator.GreaterThan,
              Ash.Query.Operator.LessThan,
              Ash.Query.Operator.GreaterThanOrEqual,
              Ash.Query.Operator.LessThanOrEqual
            ] do
    {operator, field} = unsupported_shape(expr)
    {:error, UnsupportedFilter.exception(operator: operator, field: field)}
  end

  # Equality
  defp do_translate(
         %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value, attr))
    {:ok, query, "n.#{attr.name} = #{param_ref}"}
  end

  # Not equal
  defp do_translate(
         %Ash.Query.Operator.NotEq{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    {query, param_ref} = Query.add_param(query, cast_value(value, attr))
    {:ok, query, "n.#{attr.name} <> #{param_ref}"}
  end

  # Greater than
  defp do_translate(
         %Ash.Query.Operator.GreaterThan{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    with :ok <- rangeable(attr, Ash.Query.Operator.GreaterThan) do
      {query, param_ref} = Query.add_param(query, cast_value(value, attr))
      {:ok, query, "n.#{attr.name} > #{param_ref}"}
    end
  end

  # Less than
  defp do_translate(
         %Ash.Query.Operator.LessThan{left: %Ash.Query.Ref{attribute: attr}, right: value},
         query
       ) do
    with :ok <- rangeable(attr, Ash.Query.Operator.LessThan) do
      {query, param_ref} = Query.add_param(query, cast_value(value, attr))
      {:ok, query, "n.#{attr.name} < #{param_ref}"}
    end
  end

  # Greater than or equal
  defp do_translate(
         %Ash.Query.Operator.GreaterThanOrEqual{
           left: %Ash.Query.Ref{attribute: attr},
           right: value
         },
         query
       ) do
    with :ok <- rangeable(attr, Ash.Query.Operator.GreaterThanOrEqual) do
      {query, param_ref} = Query.add_param(query, cast_value(value, attr))
      {:ok, query, "n.#{attr.name} >= #{param_ref}"}
    end
  end

  # Less than or equal
  defp do_translate(
         %Ash.Query.Operator.LessThanOrEqual{
           left: %Ash.Query.Ref{attribute: attr},
           right: value
         },
         query
       ) do
    with :ok <- rangeable(attr, Ash.Query.Operator.LessThanOrEqual) do
      {query, param_ref} = Query.add_param(query, cast_value(value, attr))
      {:ok, query, "n.#{attr.name} <= #{param_ref}"}
    end
  end

  # IN operator
  #
  # Ash's `In` operator stores `right` as a MapSet (In.new/2); normalize to a
  # list and reuse the list emission below. AGE binds `n.attr IN $param` with a
  # JSON list (probe P-S5c); an empty MapSet → empty list → matches nothing (no
  # guard needed).
  defp do_translate(
         %Ash.Query.Operator.In{left: %Ash.Query.Ref{} = ref, right: %MapSet{} = values},
         query
       ) do
    do_translate(%Ash.Query.Operator.In{left: ref, right: MapSet.to_list(values)}, query)
  end

  defp do_translate(
         %Ash.Query.Operator.In{left: %Ash.Query.Ref{attribute: attr}, right: values},
         query
       )
       when is_list(values) do
    # A Ref nested in the list is the in-list form of the attr-to-attr case the
    # guard clause above rejects for direct operands — same structural rejection.
    if Enum.any?(values, &match?(%Ash.Query.Ref{}, &1)) do
      {:error, UnsupportedFilter.exception(operator: Ash.Query.Operator.In, field: attr.name)}
    else
      {query, param_ref} = Query.add_param(query, Enum.map(values, &cast_value(&1, attr)))
      {:ok, query, "n.#{attr.name} IN #{param_ref}"}
    end
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

  # Catch-all: unsupported filter. Surface only the operator/function module and
  # the referenced field name (both structural) — never the filtered value, which
  # may be PII/secret.
  defp do_translate(expr, _query) do
    {operator, field} = unsupported_shape(expr)
    {:error, UnsupportedFilter.exception(operator: operator, field: field)}
  end

  # Value casting for AGE compatibility, typed by the ref's attribute. Binary-
  # storage values are tagged (so equality matches the stored wire form —
  # deterministic-encryption search); dates become ISO8601; refs without a type
  # (bare maps in unit tests, non-attribute refs) pass values through unchanged.
  defp cast_value(value, attr) do
    Cast.serialize_value(value, attr_type(attr))
  end

  defp attr_type(%{type: type}), do: type
  defp attr_type(_attr), do: nil

  defp attr_constraints(%{constraints: constraints}) when is_list(constraints), do: constraints
  defp attr_constraints(_attr), do: []

  # The stored form of a binary-storage value is `$age64$` + base64, and base64
  # is NOT byte-order-preserving — a range comparison on the stored form returns
  # silently wrong results. Reject it as unsupported (structural error, no value).
  defp rangeable(attr, operator) do
    if Cast.binary_storage?(attr_type(attr), attr_constraints(attr)) do
      {:error, UnsupportedFilter.exception(operator: operator, field: attr.name)}
    else
      :ok
    end
  end

  defp unsupported_shape(%mod{left: %Ash.Query.Ref{attribute: %{name: name}}}), do: {mod, name}

  defp unsupported_shape(%mod{left: %Ash.Query.Ref{attribute: name}}) when is_atom(name),
    do: {mod, name}

  defp unsupported_shape(%mod{}), do: {mod, nil}
  defp unsupported_shape(_other), do: {:unsupported_expression, nil}
end
