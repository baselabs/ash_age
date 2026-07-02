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

  Finally, it rejects an `:attribute` multitenancy discriminator whose type is
  binary-storage-typed, since the tenant filter is a plaintext comparator
  across the vertex filter, edge `$tenant` scoping, traverse per-hop scoping,
  and RLS text-cast paths, and a binary (tag-encoded) discriminator would scope
  those paths inconsistently.
  """
  use Spark.Dsl.Verifier

  alias AshAge.Type.Cast
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

    with :ok <- discriminator_not_skipped(module, strategy, attribute, skip),
         :ok <- discriminator_not_binary(dsl_state, module, strategy, attribute),
         :ok <- rls_guc_requires_attribute(module, rls_guc, strategy) do
      rls_guc_not_global(module, rls_guc, global?)
    end
  end

  defp discriminator_not_skipped(module, strategy, attribute, skip) do
    if strategy == :attribute and attribute in skip do
      {:error, skip_error(module, attribute)}
    else
      :ok
    end
  end

  defp discriminator_not_binary(dsl_state, module, strategy, attribute) do
    if strategy == :attribute and binary_discriminator?(dsl_state, attribute) do
      {:error,
       DslError.exception(
         module: module,
         path: [:multitenancy, :attribute],
         message:
           "the multitenancy attribute #{inspect(attribute)} must not be binary-storage-" <>
             "typed: the discriminator is a plaintext comparator across the vertex filter, " <>
             "edge $tenant scoping, traverse per-hop scoping, and RLS text-cast paths — a " <>
             "binary (tag-encoded) discriminator would scope those paths inconsistently."
       )}
    else
      :ok
    end
  end

  defp rls_guc_requires_attribute(_module, nil, _strategy), do: :ok
  defp rls_guc_requires_attribute(_module, _rls_guc, :attribute), do: :ok

  defp rls_guc_requires_attribute(module, _rls_guc, _strategy) do
    {:error,
     DslError.exception(
       module: module,
       path: [:age, :rls_guc],
       message:
         "`rls_guc` requires `:attribute` multitenancy. RLS scopes rows by a tenant " <>
           "property; `:context` (graph-per-tenant) is already physical isolation."
     )}
  end

  defp rls_guc_not_global(_module, nil, _global?), do: :ok
  defp rls_guc_not_global(_module, _rls_guc, false), do: :ok

  defp rls_guc_not_global(module, _rls_guc, true) do
    {:error,
     DslError.exception(
       module: module,
       path: [:age, :rls_guc],
       message:
         "`rls_guc` is incompatible with `global? true`: a global (tenantless) read " <>
           "sets no GUC, so RLS hides all rows (fail-closed but empty). Use a " <>
           "BYPASSRLS connection for global/admin access, or drop `rls_guc`."
     )}
  end

  defp binary_discriminator?(dsl_state, attribute) do
    dsl_state
    |> Verifier.get_entities([:attributes])
    |> Enum.find(&(&1.name == attribute))
    |> case do
      nil -> false
      attr -> Cast.binary_storage?(attr.type, attr.constraints)
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
