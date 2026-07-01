defmodule AshAge.Type.AgtypeTest do
  use ExUnit.Case, async: true

  alias AshAge.Type.{Agtype, Edge, Path, Vertex}

  describe "decode/1 vertices" do
    test "decodes a vertex with properties" do
      text =
        ~s({"id": 844424930131969, "label": "Person", "properties": {"name": "Usman"}}::vertex)

      assert %Vertex{id: 844_424_930_131_969, label: "Person", properties: %{"name" => "Usman"}} =
               Agtype.decode(text)
    end

    test "defaults missing properties to an empty map" do
      assert %Vertex{properties: %{}} = Agtype.decode(~s({"id": 1, "label": "X"}::vertex))
    end
  end

  describe "decode/1 edges" do
    test "decodes an edge with endpoints" do
      text =
        ~s({"id": 5, "label": "KNOWS", "end_id": 3, "start_id": 2, "properties": {"since": 2020}}::edge)

      assert %Edge{id: 5, label: "KNOWS", start_id: 2, end_id: 3, properties: %{"since" => 2020}} =
               Agtype.decode(text)
    end
  end

  describe "decode/1 paths" do
    test "splits alternating vertices and edges" do
      v1 = ~s({"id": 1, "label": "A", "properties": {}})
      e = ~s({"id": 2, "label": "R", "start_id": 1, "end_id": 3, "properties": {}})
      v2 = ~s({"id": 3, "label": "B", "properties": {}})
      text = "[#{v1}, #{e}, #{v2}]::path"

      assert %Path{vertices: [%Vertex{id: 1}, %Vertex{id: 3}], edges: [%Edge{id: 2}]} =
               Agtype.decode(text)
    end
  end

  describe "decode/1 scalars" do
    test "null / true / false" do
      assert Agtype.decode("null") == nil
      assert Agtype.decode("true") == true
      assert Agtype.decode("false") == false
    end

    test "integers and floats" do
      assert Agtype.decode("42") == 42
      assert Agtype.decode("3.14") == 3.14
    end

    test "quoted strings are JSON-decoded" do
      assert Agtype.decode(~s("hello")) == "hello"
    end

    test "non-binary input passes through" do
      assert Agtype.decode(123) == 123
    end
  end
end
