defmodule AshAge.DataLayer.Transformers.ValidateLabelFormat do
  @moduledoc """
  Transformer that validates the label format is a valid AGE identifier.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer, as: Tx
  alias Spark.Error.DslError

  def after?(AshAge.DataLayer.Transformers.EnsureLabelled), do: true
  def after?(_), do: false

  def before?(_), do: false

  def transform(dsl_state) do
    label = Tx.get_option(dsl_state, [:age], :label)

    if label do
      label_str = to_string(label)

      if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, label_str) do
        {:ok, dsl_state}
      else
        {:error,
         DslError.exception(
           path: [:age, :label],
           message:
             "Invalid label #{inspect(label)}. " <>
               "Must start with a letter or underscore and contain only alphanumeric characters and underscores."
         )}
      end
    else
      {:ok, dsl_state}
    end
  end
end
