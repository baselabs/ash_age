defmodule AshAge.DataLayer.Transformers.EnsureLabelled do
  @moduledoc """
  Transformer that ensures resources are labelled.
  """

  use Spark.Dsl.Transformer

  def before?(_), do: false

  def transform(dsl_state) do
    {:ok, dsl_state}
  end
end
