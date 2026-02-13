defmodule AshAge.Cypher.Parameterized do
  @moduledoc """
  Parameterized Cypher query builder.
  """

  @doc """
  Builds a parameterized Cypher query.
  """
  def build(_graph, cypher, params) do
    {cypher, params}
  end

  def build(_graph, cypher, params, _return_types) do
    {cypher, params}
  end

  @doc """
  Builds a static Cypher query.
  """
  def build_static(_graph, cypher) do
    {cypher, []}
  end
end
