defmodule AshAge.Integration.AtomicValidationTest do
  @moduledoc """
  Tripwire for the B1 closeout finding: an atomic validation that would VIOLATE
  must NOT write null + succeed (the silent-bypass class). Ash expands an atomic
  validation (`validate compare(...)`) to `if violation, do: error(...), else:
  ref(attr)`; the translator rejects `Error` fail-closed, so a violating update
  errors and the stored value is unchanged. A non-violating update still succeeds
  (the rejection doesn't over-reject).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule ValidatedCounter do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_closeout_b1_e2e
      repo AshAge.TestRepo
      label :ValidatedCounter
    end

    attributes do
      uuid_primary_key :id
      attribute :count, :integer, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:count]
      defaults [:read, :create]

      update :update do
        accept [:count]
        # An atomic-compatible validation → Ash expands to
        # `if count < 0, do: error(...), else: count` in the atomics.
        validate compare(:count, greater_than_or_equal_to: 0)
      end
    end
  end

  test "a violating atomic validation does NOT write null (B1 fixed)" do
    with_graph(:itest_closeout_b1_e2e, fn ->
      {:ok, c} = Ash.create(ValidatedCounter, %{count: 5})

      # Violating update: count must stay >= 0; -1 violates.
      result = c |> Ash.Changeset.for_update(:update, %{count: -1}) |> Ash.update()

      # CORRECT (B1 fixed): {:error, _} — the validation is honored (no null write).
      # B1 BYPASS (the bug): {:ok, _} with count persisted as null.
      assert {:error, _} = result,
             "B1 regression: a violating atomic validation wrote instead of erroring"

      # The stored value is unchanged (5), NOT null.
      assert Ash.get!(ValidatedCounter, c.id).count == 5
    end)
  end

  test "a non-violating atomic validation still succeeds (B1 fix doesn't over-reject)" do
    with_graph(:itest_closeout_b1_e2e, fn ->
      {:ok, c} = Ash.create(ValidatedCounter, %{count: 5})

      assert {:ok, updated} = c |> Ash.Changeset.for_update(:update, %{count: 7}) |> Ash.update()
      assert updated.count == 7
    end)
  end
end
