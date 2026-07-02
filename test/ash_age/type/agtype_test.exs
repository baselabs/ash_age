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
    # Pinned to the VERBATIM AGE `::path` wire bytes captured from a live
    # `MATCH p = (a:Node)-[:LINK]->(b:Node) RETURN p` cell. AGE tags EACH path
    # element inline with its own `::vertex`/`::edge` suffix, so the array body
    # is NOT plain JSON — decoding it as such throws Jason.DecodeError.
    test "decodes the real inline-tagged AGE path wire format" do
      text =
        ~s([{"id": 844424930131969, "label": "Node", "properties": {"id": "a"}}::vertex, {"id": 1125899906842625, "label": "LINK", "end_id": 844424930131970, "start_id": 844424930131969, "properties": {}}::edge, {"id": 844424930131970, "label": "Node", "properties": {"id": "b"}}::vertex]::path)

      assert %Path{
               vertices: [
                 %Vertex{id: 844_424_930_131_969, label: "Node", properties: %{"id" => "a"}},
                 %Vertex{id: 844_424_930_131_970, label: "Node", properties: %{"id" => "b"}}
               ],
               edges: [
                 %Edge{
                   id: 1_125_899_906_842_625,
                   label: "LINK",
                   start_id: 844_424_930_131_969,
                   end_id: 844_424_930_131_970,
                   properties: %{}
                 }
               ]
             } = Agtype.decode(text)
    end

    test "decodes an empty path" do
      assert %Path{vertices: [], edges: []} = Agtype.decode("[]::path")
    end

    test "decodes a multi-hop path preserving vertex wire order" do
      # Same inline-tagged shape AGE emits, extended to 3 vertices / 2 edges.
      text =
        ~s([{"id": 1, "label": "A", "properties": {"n": "a"}}::vertex, {"id": 10, "label": "LINK", "end_id": 2, "start_id": 1, "properties": {}}::edge, {"id": 2, "label": "B", "properties": {"n": "b"}}::vertex, {"id": 11, "label": "LINK", "end_id": 3, "start_id": 2, "properties": {}}::edge, {"id": 3, "label": "C", "properties": {"n": "c"}}::vertex]::path)

      assert %Path{
               vertices: [
                 %Vertex{id: 1, label: "A"},
                 %Vertex{id: 2, label: "B"},
                 %Vertex{id: 3, label: "C"}
               ],
               edges: [
                 %Edge{id: 10, start_id: 1, end_id: 2},
                 %Edge{id: 11, start_id: 2, end_id: 3}
               ]
             } = Agtype.decode(text)
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
