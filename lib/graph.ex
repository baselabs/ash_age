defmodule AshAge.Graph do
  @moduledoc """
  Helper functions for AGE graph management.
  """

  alias Ecto.Adapters.SQL

  @doc """
  Checks if an AGE graph exists in the database.
  """
  @spec exists?(module(), atom() | String.t()) :: boolean()
  def exists?(repo, graph_name) do
    graph_name_str = to_string(graph_name)

    query = """
    SELECT count(*) > 0
    FROM ag_catalog.ag_graph
    WHERE name = $1
    """

    case SQL.query(repo, query, [graph_name_str]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end
end
