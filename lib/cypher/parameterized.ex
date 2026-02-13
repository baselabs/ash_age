defmodule AshAge.Cypher.Parameterized do
  @moduledoc """
  Parameterized Cypher query builder for Apache AGE.

  AGE requires queries in the form:

      SELECT * FROM ag_catalog.cypher('graph_name', $$ CYPHER $$, $1) AS (v agtype)

  Where `$1` is a JSON-encoded map of parameters.
  """

  @doc """
  Builds a parameterized Cypher query wrapped for AGE execution.

  Returns `{sql_string, [json_params]}` suitable for `Ecto.Adapters.SQL.query/3`.
  """
  @spec build(atom() | String.t(), String.t(), map()) :: {String.t(), list()}
  def build(graph, cypher, params) do
    build(graph, cypher, params, [{:v, :agtype}])
  end

  @doc """
  Builds a parameterized Cypher query with custom return type columns.

  `return_types` is a keyword list like `[{:v, :agtype}, {:e, :agtype}]`.
  """
  @spec build(atom() | String.t(), String.t(), map(), keyword()) :: {String.t(), list()}
  def build(graph, cypher, params, return_types) do
    graph_name = validate_and_stringify_graph!(graph)
    columns = format_return_columns(return_types)
    json_params = Jason.encode!(params)

    sql = "SELECT * FROM ag_catalog.cypher('#{graph_name}', $$ #{cypher} $$, $1) AS (#{columns})"

    {sql, [json_params]}
  end

  @doc """
  Builds a static Cypher query (no parameters).

  Uses `NULL` for the params argument.
  """
  @spec build_static(atom() | String.t(), String.t()) :: {String.t(), list()}
  def build_static(graph, cypher) do
    build_static(graph, cypher, [{:v, :agtype}])
  end

  @doc """
  Builds a static Cypher query with custom return type columns.
  """
  @spec build_static(atom() | String.t(), String.t(), keyword()) :: {String.t(), list()}
  def build_static(graph, cypher, return_types) do
    graph_name = validate_and_stringify_graph!(graph)
    columns = format_return_columns(return_types)

    sql =
      "SELECT * FROM ag_catalog.cypher('#{graph_name}', $$ #{cypher} $$, NULL) AS (#{columns})"

    {sql, []}
  end

  defp validate_and_stringify_graph!(graph) when is_atom(graph) do
    validate_and_stringify_graph!(Atom.to_string(graph))
  end

  defp validate_and_stringify_graph!(graph) when is_binary(graph) do
    AshAge.Migration.validate_identifier!(graph)
  end

  defp format_return_columns(return_types) do
    Enum.map_join(return_types, ", ", fn {name, type} ->
      "#{name} #{type}"
    end)
  end
end
