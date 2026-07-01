defmodule AshAge.Type.CastTest do
  use ExUnit.Case, async: true

  alias AshAge.Type.{Cast, Vertex}

  defp vertex(props, id \\ nil), do: %Vertex{id: id, label: "L", properties: props}

  describe "vertex_to_resource_attrs/3" do
    test "maps known properties to attribute names" do
      attr_map = %{name: "name", age: "age"}
      types = %{name: :string, age: :integer}

      attrs =
        Cast.vertex_to_resource_attrs(vertex(%{"name" => "Ada", "age" => 36}), attr_map, types)

      assert attrs == %{name: "Ada", age: 36}
    end

    test "preserves a UUID id from properties and does not overwrite it with the vertex id" do
      attr_map = %{id: "id"}
      types = %{id: :uuid}
      uuid = "11111111-1111-1111-1111-111111111111"

      attrs =
        Cast.vertex_to_resource_attrs(
          vertex(%{"id" => uuid}, 844_424_930_131_969),
          attr_map,
          types
        )

      assert attrs.id == uuid
    end

    test "falls back to the vertex id when properties carry no id" do
      attrs = Cast.vertex_to_resource_attrs(vertex(%{}, 42), %{}, %{})
      assert attrs == %{id: 42}
    end

    test "coerces ISO8601 strings to Date/DateTime by attribute type" do
      attr_map = %{dob: "dob", seen: "seen"}
      types = %{dob: :date, seen: :utc_datetime}

      attrs =
        Cast.vertex_to_resource_attrs(
          vertex(%{"dob" => "2000-01-01", "seen" => "2026-06-30T12:00:00Z"}),
          attr_map,
          types
        )

      assert attrs.dob == ~D[2000-01-01]
      assert attrs.seen == ~U[2026-06-30 12:00:00Z]
    end

    test "returns an empty map for non-vertex input" do
      assert Cast.vertex_to_resource_attrs(:not_a_vertex, %{}, %{}) == %{}
    end
  end
end
