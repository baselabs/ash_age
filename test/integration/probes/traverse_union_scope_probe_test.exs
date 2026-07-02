defmodule AshAge.Integration.Probes.TraverseUnionScopeProbeTest do
  @moduledoc """
  Feasibility probe P-S5b-UNION (the Appendix-B fallback that gates
  :attribute-multitenant traversal after P-S5b = NO).

  P-S5b recorded **NO**: this AGE build rejects a bound path variable +
  `ALL(n IN nodes(p) WHERE ...)`, so per-hop path scoping is unavailable. The
  design's Appendix B fallback is a FIXED-LENGTH UNION expansion: for each length
  L in `min..max`, an explicit-length basic `MATCH` binding every intermediate
  node `m1..m(L-1)`, AND-ing `<node>.<attr> = $tenant` on EVERY node (source,
  each intermediate, target) — NO path variable, NO `nodes()`/`ALL()` — with the
  per-length branches UNIONed. This probe VALIDATES that that fallback binds and
  scopes correctly in this AGE build BEFORE Task 4 is built on it.

  It rehearses the UNION variant of the proven-good P-S5a building block
  (`UNWIND $ids AS sid` + basic MATCH + `WHERE a.id = sid.id` + multi-column
  RETURN through `Parameterized.build/4` with a 2-column
  `[{:s1, :agtype}, {:bid, :agtype}]` wrapper).

  RECORDED-RESULT, NOT-A-BUG framing: whatever AGE does here is a recorded
  outcome, committed GREEN. If the UNION shape works (expected) the two scenarios
  are green and record **P-S5b-UNION = YES** (Task 4 uses the exact shape these
  assertions pin). If AGE rejects the UNION syntax, the alternative single test
  asserts the `:syntax_error` and records **P-S5b-UNION = NO** — the Appendix-B
  nested contingency then forces :attribute traversal to fail closed. Either
  outcome is legitimate; neither is a defect to fix.

  Scenario 1 (cross-tenant exclusion) proves per-node scoping EXCLUDES an
  off-tenant intermediate; Scenario 2 (in-tenant reach) is the non-vacuity
  control — it proves the UNION actually TRAVERSES, so an empty Scenario 1 is a
  true exclusion and not silent breakage.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.Cypher.Parameterized
  alias AshAge.Type.Agtype
  alias Ecto.Adapters.SQL

  # Fixed-length UNION expansion for min=1..max=2, per-node tenant scoping on $t,
  # source pinned by `UNWIND $ids AS sid ... WHERE a.id = sid.id`. Basic MATCH
  # only (no path variable, no nodes()/ALL()); intermediate `m1` is UNLABELED —
  # the general case Task 4's builder must handle. Both branches RETURN the same
  # aliases (s1, bid) as the UNION requires; UNWIND is repeated in each branch.
  @union_cypher "UNWIND $ids AS sid " <>
                  "MATCH (a:Node)-[:LINK]->(b:Node) " <>
                  "WHERE a.id = sid.id AND a.t = $t AND b.t = $t " <>
                  "RETURN DISTINCT a.id AS s1, b.id AS bid " <>
                  "UNION " <>
                  "UNWIND $ids AS sid " <>
                  "MATCH (a:Node)-[:LINK]->(m1)-[:LINK]->(b:Node) " <>
                  "WHERE a.id = sid.id AND a.t = $t AND m1.t = $t AND b.t = $t " <>
                  "RETURN DISTINCT a.id AS s1, b.id AS bid"

  @params %{"ids" => [%{"id" => "a"}], "t" => "X"}
  @return_types [{:s1, :agtype}, {:bid, :agtype}]

  defp run_union(graph) do
    {sql, pg_params} = Parameterized.build(graph, @union_cypher, @params, @return_types)
    SQL.query(TestRepo, sql, pg_params)
  end

  defp reached(rows) do
    rows |> Enum.map(fn [_s1, bid] -> Agtype.decode(bid) end) |> Enum.sort()
  end

  test "P-S5b-UNION: per-node scoping EXCLUDES an off-tenant intermediate (cross-tenant)" do
    graph = "itest_probe_s5bunion_x"

    with_graph(
      graph,
      fn ->
        # a(t=X) -> m(t=Y) -> c(t=X). Every path from a passes through the
        # off-tenant m. The UNION scoped to $t="X" must therefore reach NOTHING:
        #   length-1 a->m : excluded (m.t = Y != X)
        #   length-2 a->m->c : excluded (m.t = Y != X, on the m1 intermediate)
        {:ok, _} =
          cypher_query(
            graph,
            "CREATE (a:Node {id: 'a', t: 'X'}), (m:Node {id: 'm', t: 'Y'}), " <>
              "(c:Node {id: 'c', t: 'X'}), (a)-[:LINK]->(m), (m)-[:LINK]->(c) RETURN a"
          )

        result = run_union(graph)

        assert {:ok, %{rows: rows}} = result,
               "expected the UNION expansion to run (P-S5b-UNION = YES); got #{inspect(result)}. " <>
                 "If this is {:error, %Postgrex.Error{postgres: %{code: :syntax_error}}}, AGE " <>
                 "rejects the fixed-length UNION fallback (P-S5b-UNION = NO) and :attribute " <>
                 "traversal must fail closed (Appendix B nested contingency)."

        # PASS => per-node scoping correctly EXCLUDES the off-tenant intermediate.
        assert reached(rows) == []
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  test "P-S5b-UNION: UNION actually TRAVERSES in-tenant (non-vacuity control)" do
    graph = "itest_probe_s5bunion_reach"

    with_graph(
      graph,
      fn ->
        # a(t=X) -> b(t=X) -> c(t=X), all tenant X. Scoped to $t="X":
        #   length-1 reaches b
        #   length-2 reaches c (via b, b.t = X ok as the m1 intermediate)
        # Proves the mechanism is not vacuously empty; without this control an
        # empty Scenario 1 could be a false pass from silent breakage.
        {:ok, _} =
          cypher_query(
            graph,
            "CREATE (a:Node {id: 'a', t: 'X'}), (b:Node {id: 'b', t: 'X'}), " <>
              "(c:Node {id: 'c', t: 'X'}), (a)-[:LINK]->(b), (b)-[:LINK]->(c) RETURN a"
          )

        result = run_union(graph)

        assert {:ok, %{rows: rows}} = result,
               "expected the UNION expansion to run (P-S5b-UNION = YES); got #{inspect(result)}."

        # PASS => the UNION genuinely traverses both lengths within the tenant.
        assert reached(rows) == ["b", "c"]
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end
end
