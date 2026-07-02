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
    cypher = validate_cypher_body!(cypher)
    columns = format_return_columns(return_types)
    json_params = Jason.encode!(params)

    sql = "SELECT * FROM ag_catalog.cypher('#{graph_name}', $$ #{cypher} $$, $1) AS (#{columns})"

    {sql, [json_params]}
  end

  @doc """
  Builds a static Cypher query (no parameters).

  Omits the params argument entirely — AGE rejects `NULL` as the third argument.
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
    cypher = validate_cypher_body!(cypher)
    columns = format_return_columns(return_types)

    sql =
      "SELECT * FROM ag_catalog.cypher('#{graph_name}', $$ #{cypher} $$) AS (#{columns})"

    {sql, []}
  end

  # Defense-in-depth: the cypher body is interpolated between AGE's `$$ ... $$`
  # dollar-quote delimiters. Every identifier that reaches it is validated at its
  # source (graph/label/field/property-key), but as a final centralized guard we
  # reject any body carrying a `$$` sequence — the only way to break out of the
  # dollar-quoted literal. This library never legitimately emits `$$` (all values
  # are parameterized via `$1`), so this can only fire on a smuggled identifier.
  defp validate_cypher_body!(cypher) when is_binary(cypher) do
    if String.contains?(cypher, "$$") do
      # The body is NOT echoed: this raise is not routed through the redaction
      # boundary, and a caller that mistakenly interpolated a value into the body
      # would otherwise leak it into logs (AGENTS.md rule 5).
      raise ArgumentError, "Cypher body must not contain \"$$\" (would break AGE dollar-quoting)"
    end

    cypher
  end

  defp validate_and_stringify_graph!(graph) when is_atom(graph) do
    validate_and_stringify_graph!(Atom.to_string(graph))
  end

  defp validate_and_stringify_graph!(graph) when is_binary(graph) do
    AshAge.Migration.validate_identifier!(graph)
  end

  # `return_types` column names/types are interpolated into the outer `AS (...)`
  # SQL, OUTSIDE AGE's `$$` dollar-quote — so on the public `AshAge.cypher/5`
  # surface they are a caller-controlled injection vector. Validate both as AGE
  # identifiers, the same guard applied to the graph name.
  defp format_return_columns(return_types) do
    Enum.map_join(return_types, ", ", fn {name, type} ->
      name = name |> to_string() |> AshAge.Migration.validate_identifier!()
      type = type |> to_string() |> AshAge.Migration.validate_identifier!()
      "#{name} #{type}"
    end)
  end
end
