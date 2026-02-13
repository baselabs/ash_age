defmodule AshAge.DataLayer.Transformers.DefaultRelate do
  @moduledoc """
  Transformer for default relationships.
  """

  use Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl_state) do
    {:ok, dsl_state}
  end
end
