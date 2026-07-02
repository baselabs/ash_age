defmodule AshAge.Integration.BackwardCompatTest do
  @moduledoc """
  A resource with no `multitenancy` block must behave byte-identically to
  pre-S3: writes target `Info.graph/1`, `set_tenant/3` never fires, and CRUD is
  unchanged. Release-gating per spec §2.3.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.DataLayer.Info

  defmodule Plain do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s3_plain)
      repo(AshAge.TestRepo)
      label(:Plain)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  test "no-multitenancy resource uses the base graph and full CRUD works" do
    # write_graph resolves the base graph regardless of any tenant.
    assert AshAge.DataLayer.write_graph(Plain, %{to_tenant: "irrelevant"}) ==
             {:ok, :itest_s3_plain}

    with_graph(
      "itest_s3_plain",
      fn ->
        {:ok, p} = Plain |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create()
        assert {:ok, [got]} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
        assert got.id == p.id

        {:ok, p2} = p |> Ash.Changeset.for_update(:update, %{name: "y"}) |> Ash.update()
        assert p2.name == "y"

        :ok = p2 |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()
        assert {:ok, []} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
      end,
      vlabels: ["Plain"]
    )
  end

  test "a resource without rls_guc behaves identically (RLS off = with_rls pass-through)" do
    assert Info.rls_guc(Plain) == nil

    with_graph(
      "itest_s3_plain",
      fn ->
        {:ok, p} = Plain |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create()
        assert {:ok, [got]} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
        assert got.id == p.id

        {:ok, p2} = p |> Ash.Changeset.for_update(:update, %{name: "y"}) |> Ash.update()
        assert p2.name == "y"

        :ok = p2 |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()
        assert {:ok, []} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
      end,
      vlabels: ["Plain"]
    )
  end

  test "destroy of an absent row returns StaleRecord (S3 0-row semantics, reaches plain resources)" do
    with_graph(
      "itest_s3_plain",
      fn ->
        {:ok, p} = Plain |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create()
        :ok = p |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()

        # Second destroy of the same (now-absent) row matches 0 rows. Pre-S3 this
        # returned :ok unconditionally; S3 returns StaleRecord — the Ash contract
        # signal for a record-based mutation that matched nothing (what the
        # reference ETS data layer and Ash core do). Documented in CHANGELOG.
        assert {:error, err} = p |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()

        assert Enum.any?(
                 List.wrap(Map.get(err, :errors, [err])),
                 &match?(%Ash.Error.Changes.StaleRecord{}, &1)
               ),
               "expected StaleRecord for a 0-row destroy, got: #{inspect(err)}"
      end,
      vlabels: ["Plain"]
    )
  end
end
