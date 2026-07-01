defmodule AshAge.Integration.Probes.EdgeCreateProbeTest do
  @moduledoc """
  Feasibility probe P2 (gates S4 edge-create). Asserts the hoped-for capability:
  AGE accepts a parameterized `MATCH (a),(b) WHERE ... CREATE (a)-[:REL]->(b)`, and
  that the edge is persisted and traversable via an INDEPENDENT read-back (not only
  the CREATE statement's own `RETURN`). A failure here is a RECORDED result
  (P2 = no → S4 finds the working AGE edge shape), not a bug to fix.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.Type.Agtype

  test "P2: AGE accepts parameterized MATCH (a),(b) ... CREATE (a)-[:REL]->(b)" do
    with_graph(
      "itest_probe_p2",
      fn ->
        # Seed two vertices.
        assert {:ok, _} =
                 cypher_query(
                   "itest_probe_p2",
                   "CREATE (a:Node) SET a.name = $a CREATE (b:Node) SET b.name = $b RETURN a",
                   %{"a" => "src", "b" => "dst"}
                 )

        # Create the edge between them.
        create =
          cypher_query(
            "itest_probe_p2",
            "MATCH (a:Node), (b:Node) WHERE a.name = $a AND b.name = $b CREATE (a)-[e:REL]->(b) RETURN e",
            %{"a" => "src", "b" => "dst"}
          )

        # PASS => P2 = yes (S4 edge create uses this shape). {:error, ...} => P2 = no.
        assert {:ok, %{num_rows: 1}} = create

        # Independent read-back: the edge is persisted and traversable, proving the
        # CREATE landed a real relationship — not just that the statement returned a row.
        readback = cypher_query("itest_probe_p2", "MATCH (:Node)-[:REL]->(b:Node) RETURN b.name")
        assert {:ok, %{num_rows: 1, rows: [[dst]]}} = readback
        assert Agtype.decode(dst) == "dst"
      end,
      vlabels: ["Node"],
      elabels: ["REL"]
    )
  end
end
