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
    sort: []
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
          sort: [{atom(), :asc | :desc}]
        }

  @doc """
  Converts a query to Cypher with parameters.
  """
  @spec to_cypher(t()) :: {String.t(), map()}
  def to_cypher(%__MODULE__{} = query) do
    base = "MATCH (n:#{query.label} {$params})"

    {where, params} =
      if query.expression do
        case AshAge.Query.Filter.translate(query.expression, query) do
          {:ok, _query, clause} -> {clause, %{}}
          _ -> {"", %{}}
        end
      else
        {"", %{}}
      end

    cypher =
      base <>
        if where == "" do
          ""
        else
          " WHERE " <> where
        end

    {cypher, params}
  end

  @doc """
  Adds a parameter to the query.
  """
  def add_param(query, _value) do
    {query, "$param#{map_size(query.expression || {}) + 1}"}
  end
end
