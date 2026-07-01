defmodule AshAge.Integration.DataLayerRoundtripTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule Person do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_roundtrip
      repo AshAge.TestRepo
      label :Person
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:name]
      defaults [:read, :create, :update, :destroy]
    end
  end

  test "creates and reads back a vertex through the data layer" do
    with_graph(
      "itest_roundtrip",
      fn ->
        {:ok, created} =
          Person
          |> Ash.Changeset.for_create(:create, %{name: "Ada"})
          |> Ash.create()

        assert created.name == "Ada"
        assert is_binary(created.id)

        [read] = Ash.read!(Person)
        assert read.id == created.id
        assert read.name == "Ada"
      end,
      vlabels: ["Person"]
    )
  end
end
