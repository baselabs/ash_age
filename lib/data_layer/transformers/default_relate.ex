defmodule AshAge.DataLayer.Transformers.DefaultRelate do
  @moduledoc false
  # Reserved no-op transformer: a registered seam for future default-relationship
  # derivation. `transform/1` returns the DSL state unchanged, so it is inert
  # today — kept in the pipeline so adding derivation later needs no wiring.

  use Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl_state) do
    {:ok, dsl_state}
  end
end
