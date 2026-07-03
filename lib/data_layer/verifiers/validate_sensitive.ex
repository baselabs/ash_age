defmodule AshAge.DataLayer.Verifiers.ValidateSensitive do
  @moduledoc """
  Raises a `Spark.Error.DslError` at compile verification when the
  `age do sensitive [...] end` classification cannot hold (Spark surfaces
  verifier errors as compiler diagnostics — build-blocking under
  `--warnings-as-errors`):

  - **R1** — every listed name is a declared attribute. A typo would silently
    protect nothing.
  - **R2** — every sensitive attribute is binary-storage-typed
    (`Ash.Type.storage_type == :binary`: app-side-encrypted bytes, `$age64$`
    round-trip) or listed in `skip` (never written to the graph).
  - **R3** — the multitenancy discriminator is not sensitive. It is a plaintext
    selector by design: Ash core injects it as a plaintext filter/force-set,
    and ash_age holds no key material to encrypt it.
  - **R4** — an `edge` `properties` key naming a sensitive attribute requires
    every same-named DECLARED action argument to be binary-storage-typed;
    otherwise the classified datum flows onto edges as plaintext through a
    same-named plaintext argument. (`AshAge.Changes.CreateEdge` enforces the
    runtime half for undeclared/injected arguments.)

  The verifier checks a TYPE SHAPE, not encryption: a `:binary` attribute
  holding plaintext bytes passes. Encrypting is the host app's obligation —
  ash_age cannot verify ciphertext.
  """
  use Spark.Dsl.Verifier

  alias AshAge.Type.Cast
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    case Verifier.get_option(dsl_state, [:age], :sensitive, []) do
      [] -> :ok
      sensitive -> do_verify(dsl_state, sensitive)
    end
  end

  defp do_verify(dsl_state, sensitive) do
    module = Verifier.get_persisted(dsl_state, :module)
    skip = Verifier.get_option(dsl_state, [:age], :skip, [])
    attributes = Verifier.get_entities(dsl_state, [:attributes])
    attr_by_name = Map.new(attributes, &{&1.name, &1})
    tenant_attr = Verifier.get_option(dsl_state, [:multitenancy], :attribute)

    with :ok <- known_attributes(module, sensitive, attr_by_name),
         :ok <- not_the_discriminator(module, sensitive, tenant_attr),
         :ok <- encrypted_or_skipped(module, sensitive, attr_by_name, skip) do
      edge_property_arguments(module, sensitive, dsl_state)
    end
  end

  # R1
  defp known_attributes(module, sensitive, attr_by_name) do
    case Enum.reject(sensitive, &Map.has_key?(attr_by_name, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         DslError.exception(
           module: module,
           path: [:age, :sensitive],
           message:
             "#{inspect(unknown)} in `sensitive` is not a declared attribute. " <>
               "A typo here would silently protect nothing, so it fails closed."
         )}
    end
  end

  # R3
  defp not_the_discriminator(_module, _sensitive, nil), do: :ok

  defp not_the_discriminator(module, sensitive, tenant_attr) do
    if tenant_attr in sensitive do
      {:error,
       DslError.exception(
         module: module,
         path: [:age, :sensitive],
         message:
           "the multitenancy attribute #{inspect(tenant_attr)} cannot be `sensitive`: " <>
             "it is a plaintext selector by design (Ash core injects it as a plaintext " <>
             "filter and force-set; ash_age holds no key material to encrypt it)."
       )}
    else
      :ok
    end
  end

  # R2
  defp encrypted_or_skipped(module, sensitive, attr_by_name, skip) do
    offender =
      Enum.find(sensitive, fn name ->
        # safe: R1 (known_attributes) guaranteed membership before this runs
        attr = Map.fetch!(attr_by_name, name)
        name not in skip and not Cast.binary_storage?(attr.type, attr.constraints)
      end)

    case offender do
      nil ->
        :ok

      name ->
        {:error,
         DslError.exception(
           module: module,
           path: [:age, :sensitive],
           message:
             "sensitive attribute #{inspect(name)} must be binary-storage-typed or listed " <>
               "in `skip`. A sensitive attribute stored as plaintext defeats the " <>
               "classification; store app-side-encrypted bytes in a :binary-typed " <>
               "attribute, or skip it so it never reaches the graph."
         )}
    end
  end

  # R4
  defp edge_property_arguments(module, sensitive, dsl_state) do
    edge_keys =
      dsl_state
      |> Verifier.get_entities([:age])
      |> Enum.filter(&match?(%AshAge.Edge{}, &1))
      |> Enum.flat_map(& &1.properties)
      |> Enum.filter(&(&1 in sensitive))
      |> Enum.uniq()

    if edge_keys == [] do
      :ok
    else
      offending =
        dsl_state
        |> Verifier.get_entities([:actions])
        |> Enum.find_value(&offending_argument(&1, edge_keys))

      case offending do
        nil ->
          :ok

        {action_name, arg_name} ->
          {:error,
           DslError.exception(
             module: module,
             path: [:age, :sensitive],
             message:
               "edge property #{inspect(arg_name)} names a sensitive attribute, so every " <>
                 "same-named action argument must be a binary-storage-typed declared " <>
                 "action argument — otherwise the classified datum reaches edges as " <>
                 "plaintext. Offending argument on action #{inspect(action_name)}; " <>
                 "retype it :binary or rename it."
           )}
      end
    end
  end

  # `{action_name, arg_name}` for the first non-binary-storage declared argument
  # whose name collides with a sensitive edge-property key; nil when the action
  # is clean. Keeps the action name so the R4 error can say WHERE.
  defp offending_argument(action, edge_keys) do
    (Map.get(action, :arguments) || [])
    |> Enum.find(fn arg ->
      arg.name in edge_keys and not Cast.binary_storage?(arg.type, arg.constraints)
    end)
    |> case do
      nil -> nil
      arg -> {action.name, arg.name}
    end
  end
end
