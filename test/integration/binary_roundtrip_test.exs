defmodule AshAge.Integration.BinaryRoundtripTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule Blob do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s2_binary
      repo AshAge.TestRepo
      label :Blob
    end

    attributes do
      uuid_primary_key :id
      attribute :payload, :binary, public?: true
    end

    actions do
      default_accept [:payload]
      defaults [:read, :create, :update, :destroy]
    end
  end

  test "round-trips a non-UTF-8 :binary attribute through AGE (AshCloak-shaped bytes)" do
    bytes = <<0, 255, 16, 128, 1, 250>>

    with_graph(
      "itest_s2_binary",
      fn ->
        {:ok, created} =
          Blob |> Ash.Changeset.for_create(:create, %{payload: bytes}) |> Ash.create()

        assert created.payload == bytes

        [read] = Ash.read!(Blob)
        assert read.payload == bytes
      end,
      vlabels: ["Blob"]
    )
  end
end
