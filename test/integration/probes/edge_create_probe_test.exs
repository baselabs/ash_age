defmodule AshAge.Integration.Probes.EdgeCreateProbeTest do
  @moduledoc """
  Feasibility probe P2 (gates S4 edge-create). Asserts the hoped-for capability:
  AGE accepts a parameterized `MATCH (a),(b) WHERE ... CREATE (a)-[:REL]->(b)`.
  A failure here is a RECORDED result (P2 = no → S4 finds the working AGE edge
  shape), not a bug to fix.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.Cypher.Parameterized

  test "P2: AGE accepts parameterized MATCH (a),(b) ... CREATE (a)-[:REL]->(b)" do
    with_graph("itest_probe_p2", [vlabels: ["Node"], elabels: ["REL"]], fn ->
      {seed_sql, seed_params} =
        Parameterized.build(
          "itest_probe_p2",
          "CREATE (a:Node) SET a.name = $a CREATE (b:Node) SET b.name = $b RETURN a",
          %{"a" => "src", "b" => "dst"}
        )

      {:ok, _} = Ecto.Adapters.SQL.query(AshAge.TestRepo, seed_sql, seed_params)

      cypher = """
      MATCH (a:Node), (b:Node)
      WHERE a.name = $a AND b.name = $b
      CREATE (a)-[e:REL]->(b)
      RETURN e
      """

      {sql, pg_params} =
        Parameterized.build("itest_probe_p2", cypher, %{"a" => "src", "b" => "dst"})

      result = Ecto.Adapters.SQL.query(AshAge.TestRepo, sql, pg_params)

      # PASS => P2 = yes (S4 edge create uses this shape). {:error, ...} => P2 = no.
      assert {:ok, %{num_rows: 1}} = result
    end)
  end
end
