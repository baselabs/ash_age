defmodule AshAge.Integration.Probes.PathPredicateProbeTest do
  @moduledoc """
  Feasibility probe P-S5b (gates :attribute-multitenant traversal's per-hop
  scoping). RECORDED RESULT: **P-S5b = NO** — this AGE build's Cypher parser
  rejects a bound path variable + `ALL(n IN nodes(p) WHERE n.prop = $v)` with a
  syntax error. Consequently :attribute-multitenant traversal CANNOT use per-hop
  path scoping; Task 4 uses the fixed-length UNION expansion fallback (basic MATCH
  only, explicit intermediate-node binding — Appendix B). This test asserts the
  rejection so it stays green and acts as a regression tripwire: if a future AGE
  upgrade adds `ALL(nodes(p))` support this test goes RED, signalling that the
  cleaner per-hop predicate can replace the UNION expansion.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  test "P-S5b = NO: AGE rejects ALL(n IN nodes(p) WHERE ...) on a variable-length path" do
    with_graph(
      "itest_probe_s5b",
      fn ->
        # a(t=X) -> m(t=Y) -> c(t=X): the seed the hoped-for per-hop predicate would
        # have scoped. It is irrelevant now — the query is rejected at parse time.
        {:ok, _} =
          cypher_query(
            "itest_probe_s5b",
            "CREATE (a:Node {id: 'a', t: 'X'}), (m:Node {id: 'm', t: 'Y'}), " <>
              "(c:Node {id: 'c', t: 'X'}), (a)-[:LINK]->(m), (m)-[:LINK]->(c) RETURN a"
          )

        cypher =
          "UNWIND $ids AS sid " <>
            "MATCH p = (a:Node)-[:LINK*1..3]->(b:Node) " <>
            "WHERE a.id = sid.id AND ALL(n IN nodes(p) WHERE n.t = $t) " <>
            "RETURN DISTINCT b.id AS bid"

        result = cypher_query("itest_probe_s5b", cypher, %{"ids" => [%{"id" => "a"}], "t" => "X"})

        assert match?({:error, %Postgrex.Error{postgres: %{code: :syntax_error}}}, result),
               "expected AGE to reject ALL(nodes(p)) with a syntax error (P-S5b = NO); " <>
                 "got #{inspect(result)}. If this is now {:ok, _}, AGE gained ALL(nodes(p)) " <>
                 "support — revisit Task 4 to prefer per-hop scoping over the UNION fallback."
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end
end
