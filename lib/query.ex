defmodule AshAge.Query do
  @moduledoc """
  Query structure for AGE graph queries.
  """

  defstruct [
    :resource,
    :graph,
    :label,
    :repo,
    :expression,
    :limit,
    :offset,
    filters: [],
    sort: [],
    params: %{}
  ]

  @type t :: %__MODULE__{
          resource: module(),
          graph: atom(),
          label: atom() | String.t(),
          repo: module(),
          expression: Ash.Filter.t() | nil,
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          filters: [String.t()],
          sort: [{atom(), :asc | :desc}],
          params: map()
        }

  @doc """
  Converts a query to Cypher with parameters.

  Returns `{cypher_string, params_map}`.
  """
  @spec to_cypher(t()) :: {String.t(), map()}
  def to_cypher(%__MODULE__{} = query) do
    {where_parts, query} = build_where(query)

    parts =
      ["MATCH (n:#{query.label})"] ++
        build_where_clause(where_parts) ++
        ["RETURN n"] ++
        build_order_by(query.sort) ++
        build_skip(query.offset) ++
        build_limit(query.limit)

    {Enum.join(parts, " "), query.params}
  end

  @doc """
  Adds a parameter to the query, returning the updated query and a `$paramN` reference.
  """
  @spec add_param(t(), term()) :: {t(), String.t()}
  def add_param(%__MODULE__{params: params} = query, value) do
    key = "param#{map_size(params) + 1}"
    {%{query | params: Map.put(params, key, value)}, "$#{key}"}
  end

  defp build_where(query) do
    filter_clauses = query.filters

    {expression_clauses, query} =
      if query.expression do
        case AshAge.Query.Filter.translate(query.expression, query) do
          {:ok, query, ""} -> {[], query}
          {:ok, query, clause} -> {[clause], query}
          _ -> {[], query}
        end
      else
        {[], query}
      end

    {filter_clauses ++ expression_clauses, query}
  end

  defp build_where_clause([]), do: []

  defp build_where_clause(parts) do
    ["WHERE " <> Enum.join(parts, " AND ")]
  end

  defp build_order_by([]), do: []

  defp build_order_by(sort_clauses) do
    order =
      Enum.map_join(sort_clauses, ", ", fn {field, direction} ->
        dir = if direction == :desc, do: "DESC", else: "ASC"
        "n.#{field} #{dir}"
      end)

    ["ORDER BY " <> order]
  end

  defp build_skip(nil), do: []
  defp build_skip(offset), do: ["SKIP #{offset}"]

  defp build_limit(nil), do: []
  defp build_limit(limit), do: ["LIMIT #{limit}"]
end
