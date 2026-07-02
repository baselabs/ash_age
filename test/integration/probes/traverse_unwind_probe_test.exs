defmodule AshAge.Integration.Probes.TraverseUnwindProbeTest do
  @moduledoc """
  Feasibility probe P-S5a (gates all S5 traversal). Asserts the hoped-for shape:
  AGE binds `UNWIND $ids AS sid` (list-of-maps param) combined with a
  variable-length `MATCH (a)-[:L*1..k]->(b)` and map-access `a.pk = sid.pk`
  (the same list-param + `x.key` mechanism P1 proved for bulk create). A failure
  here is a RECORDED result (P-S5a = no → fall back to per-source scalar queries;
  NEVER literal-interpolate the id list), not a bug to fix.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.Cypher.Parameterized
  alias AshAge.Type.Agtype
  alias Ecto.Adapters.SQL

  test "P-S5a: AGE binds UNWIND $ids + variable-length MATCH + map-access match" do
    with_graph(
      "itest_probe_s5a",
      fn ->
        # Seed a 2-hop chain a -> b -> c, all :Node, edge :LINK.
        {:ok, _} =
          cypher_query(
            "itest_probe_s5a",
            "CREATE (a:Node {id: 'a'}), (b:Node {id: 'b'}), (c:Node {id: 'c'}), " <>
              "(a)-[:LINK]->(b), (b)-[:LINK]->(c) RETURN a"
          )

        cypher =
          "UNWIND $ids AS sid " <>
            "MATCH (a:Node)-[:LINK*1..2]->(b:Node) " <>
            "WHERE a.id = sid.id " <>
            "RETURN DISTINCT a.id AS s1, b.id AS bid"

        # Built DIRECTLY via Parameterized.build/4 with a TWO-column wrapper.
        # cypher_query/3 hardcodes the single-column `AS (v agtype)` wrapper
        # (data_case.ex:63-72), so routing this 2-column RETURN through it makes
        # AGE reject the query — a FALSE "P-S5a = no". The probe must rehearse
        # Task 4's exact shape: multi-column `sN…, b` through Parameterized.build/4.
        {sql, pg_params} =
          Parameterized.build("itest_probe_s5a", cypher, %{"ids" => [%{"id" => "a"}]}, [
            {:s1, :agtype},
            {:bid, :agtype}
          ])

        # From 'a', depth 1..2 reaches b and c.
        assert {:ok, %{rows: rows}} = SQL.query(TestRepo, sql, pg_params)

        reached = rows |> Enum.map(fn [_s1, bid] -> Agtype.decode(bid) end) |> Enum.sort()
        # PASS => P-S5a = yes (Task 4 uses this exact mechanism).
        # {:error, %Postgrex.Error{}} => P-S5a = no (record it, use the fallback).
        assert reached == ["b", "c"]
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end
end
