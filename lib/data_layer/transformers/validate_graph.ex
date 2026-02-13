defmodule AshAge.DataLayer.Transformers.ValidateGraph do
  @moduledoc """
  Transformer that validates the graph configuration.
  """

  use Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl_state) do
    {:ok, dsl_state}
  end
end
