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

  defmodule Mappy do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s7_mappy
      repo AshAge.TestRepo
      label :Mappy
    end

    attributes do
      uuid_primary_key :id
      attribute :meta, :map, public?: true
    end

    actions do
      default_accept [:meta]
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

  test "raw bytes nested in a :map attribute fail closed with NO byte leak (S7)" do
    secret = <<0, 255, 42, 128>>

    with_graph(
      "itest_s7_mappy",
      fn ->
        result =
          Mappy
          |> Ash.Changeset.for_create(:create, %{meta: %{"blob" => secret}})
          |> Ash.create()

        # Pinned wrapper class: CreateFailed is class :invalid, so Ash wraps the
        # returned tuple in Ash.Error.Invalid — a RETURN, never a raise.
        assert {:error, %Ash.Error.Invalid{} = error} = result
        message = Exception.message(error)
        # attr name is structural and allowed; the bytes are not, in any encoding
        assert message =~ "meta"
        refute String.contains?(message, secret)
        refute message =~ Base.encode64(secret)
        refute message =~ inspect(secret)
      end,
      vlabels: ["Mappy"]
    )
  end
end
