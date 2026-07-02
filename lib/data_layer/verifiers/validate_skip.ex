defmodule AshAge.DataLayer.Verifiers.ValidateSkip do
  @moduledoc """
  Fails compilation when a primary-key attribute appears in `age do skip [...]`.

  A skipped attribute is never written as a graph property, but update/destroy
  always MATCH on the full primary key — so a skipped PK makes every mutation
  match zero rows and return StaleRecord, with no runtime signal of why. Reads
  decode a struct whose PK is nil. Fail closed at compile time instead.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    skip = Verifier.get_option(dsl_state, [:age], :skip, [])

    pk_in_skip =
      dsl_state
      |> Verifier.get_entities([:attributes])
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)
      |> Enum.filter(&(&1 in skip))

    case pk_in_skip do
      [] ->
        :ok

      bad ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:age, :skip],
           message:
             "primary key attribute(s) #{inspect(bad)} must not be in `skip`: the PK " <>
               "property would never be written, so every update/destroy matches zero " <>
               "rows (perpetual StaleRecord) and reads decode a nil primary key."
         )}
    end
  end
end
