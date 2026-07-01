defmodule AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr do
  @moduledoc """
  Fails compilation when a resource using `:attribute` multitenancy lists the
  multitenancy attribute in `age do skip [...] end`.

  If the discriminator is skipped, ash_age never writes it as a graph property,
  so the tenant filter Ash core injects on reads silently matches nothing — a
  fail-open isolation hole with no runtime signal. This verifier turns that into
  a compile error. It is additive to Ash's own `ValidateMultitenancy` (which
  checks the attribute exists); this closes only the skip-list hole.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    strategy = Verifier.get_option(dsl_state, [:multitenancy], :strategy)
    attribute = Verifier.get_option(dsl_state, [:multitenancy], :attribute)
    skip = Verifier.get_option(dsl_state, [:age], :skip, [])

    if strategy == :attribute and attribute in skip do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl_state, :module),
         path: [:age, :skip],
         message:
           "The multitenancy attribute #{inspect(attribute)} must not appear in " <>
             "`age do skip [...]`. Skipping it means the tenant discriminator is never " <>
             "written to the graph, so the tenant filter Ash injects on reads matches " <>
             "nothing (fail-open isolation)."
       )}
    else
      :ok
    end
  end
end
