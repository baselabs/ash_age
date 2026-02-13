defmodule AshAge.DataLayer.Transformers.EnsureLabelled do
  @moduledoc """
  Transformer that ensures resources have a label set.

  If no `:label` is configured, defaults to the resource module's short name
  (e.g., `MyApp.Entity` → `"Entity"`).
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer, as: Tx

  def after?(AshAge.DataLayer.Transformers.ValidateGraph), do: true
  def after?(_), do: false

  def before?(_), do: false

  def transform(dsl_state) do
    label = Tx.get_option(dsl_state, [:age], :label)

    if label do
      {:ok, dsl_state}
    else
      module = Tx.get_persisted(dsl_state, :module)

      default =
        module
        |> Module.split()
        |> List.last()

      {:ok, Tx.set_option(dsl_state, [:age], :label, default)}
    end
  end
end
