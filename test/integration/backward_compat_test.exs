defmodule AshAge.Integration.BackwardCompatTest do
  @moduledoc """
  A resource with no `multitenancy` block must behave byte-identically to
  pre-S3: writes target `Info.graph/1`, `set_tenant/3` never fires, and CRUD is
  unchanged. Release-gating per spec §2.3.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

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
end
