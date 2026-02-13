defmodule AshAge.DataLayer.Transformers.ValidateGraph do
  @moduledoc """
  Transformer that validates the graph name is a valid AGE identifier.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer, as: Tx
  alias Spark.Error.DslError

  def before?(_), do: true

  def transform(dsl_state) do
    graph = Tx.get_option(dsl_state, [:age], :graph)

    if graph do
      graph_str = to_string(graph)

      if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, graph_str) do
        {:ok, dsl_state}
      else
        {:error,
         DslError.exception(
           path: [:age, :graph],
           message:
             "Invalid graph name #{inspect(graph)}. " <>
               "Must start with a letter or underscore and contain only alphanumeric characters and underscores."
         )}
      end
    else
      {:ok, dsl_state}
    end
  end
end
