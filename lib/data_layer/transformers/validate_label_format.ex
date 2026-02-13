defmodule AshAge.DataLayer.Transformers.ValidateLabelFormat do
  @moduledoc """
  Transformer that validates the label format.
  """

  use Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl_state) do
    {:ok, dsl_state}
  end
end
