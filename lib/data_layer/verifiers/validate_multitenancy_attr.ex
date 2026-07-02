defmodule AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr do
  @moduledoc """
  Fails compilation when a resource using `:attribute` multitenancy lists the
  multitenancy attribute in `age do skip [...] end`.

  If the discriminator is skipped, ash_age never writes it as a graph property,
  so the tenant filter Ash core injects on reads silently matches nothing — a
  fail-open isolation hole with no runtime signal. This verifier turns that into
  a compile error. It is additive to Ash's own `ValidateMultitenancy` (which
  checks the attribute exists); this closes only the skip-list hole.

  It also enforces two `age do rls_guc "..." end` invariants. `rls_guc` requires
  `:attribute` multitenancy — RLS scopes rows by a tenant property, whereas
  `:context` (graph-per-tenant) is already physical isolation — so it errors on a
  `:context` resource. And `rls_guc` is incompatible with `global? true`: a
  global (tenantless) read sets no GUC, so RLS would hide all rows; that
  combination is rejected rather than silently returning an empty result.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    strategy = Verifier.get_option(dsl_state, [:multitenancy], :strategy)
    attribute = Verifier.get_option(dsl_state, [:multitenancy], :attribute)
    global? = Verifier.get_option(dsl_state, [:multitenancy], :global?, false)
    skip = Verifier.get_option(dsl_state, [:age], :skip, [])
    rls_guc = Verifier.get_option(dsl_state, [:age], :rls_guc, nil)
    module = Verifier.get_persisted(dsl_state, :module)

    cond do
      strategy == :attribute and attribute in skip ->
        {:error, skip_error(module, attribute)}

      not is_nil(rls_guc) and strategy != :attribute ->
        {:error,
         DslError.exception(
           module: module,
           path: [:age, :rls_guc],
           message:
             "`rls_guc` requires `:attribute` multitenancy. RLS scopes rows by a tenant " <>
               "property; `:context` (graph-per-tenant) is already physical isolation."
         )}

      not is_nil(rls_guc) and global? ->
        {:error,
         DslError.exception(
           module: module,
           path: [:age, :rls_guc],
           message:
             "`rls_guc` is incompatible with `global? true`: a global (tenantless) read " <>
               "sets no GUC, so RLS hides all rows (fail-closed but empty). Use a " <>
               "BYPASSRLS connection for global/admin access, or drop `rls_guc`."
         )}

      true ->
        :ok
    end
  end

  defp skip_error(module, attribute) do
    DslError.exception(
      module: module,
      path: [:age, :skip],
      message:
        "The multitenancy attribute #{inspect(attribute)} must not appear in " <>
          "`age do skip [...]`. Skipping it means the tenant discriminator is never " <>
          "written to the graph, so the tenant filter Ash injects on reads matches " <>
          "nothing (fail-open isolation)."
    )
  end
end
