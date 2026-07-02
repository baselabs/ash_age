defmodule AshAge.Integration.Probes.InFilterParamProbeTest do
  @moduledoc """
  Feasibility probe P-S5c — gates the `In`-filter MapSet fix.

  A pre-existing data-layer bug: `AshAge.Query.Filter`'s `In` translator matches
  only `when is_list(values)`, but Ash's `In` operator stores `right` as a
  `MapSet`, so `id in [...]` filters fall through to `UnsupportedFilter`. The fix
  (next task) normalizes the MapSet to a list and emits `n.<attr> IN $param`. BUT
  that `IN $param` Cypher shape has NEVER run against live AGE — the `is_list`
  clause is dead code because Ash never passes a bare list. This probe determines
  whether AGE binds `WHERE n.<attr> IN $param` with a JSON-list param, which gates
  HOW the filter fix is written.

  The exact shape the fixed filter will emit (verified from `AshAge.Query`'s
  `add_param/2` + `AshAge.Query.Filter`): the value list goes into the params map
  under a key like `paramN`, the Cypher references it as `$paramN`, and the whole
  params map is JSON-encoded as one agtype object by `Parameterized.build/4`. So
  this probe tests a **list-valued param referenced via `IN $key`**, exactly the
  production emission shape.

  RECORDED-RESULT, NOT-A-BUG framing: whatever AGE does here is a recorded outcome,
  committed GREEN. Expected: YES (AGE binds `IN $param`) — Scenario 1 genuinely
  returns the listed members and Scenario 2 pins the empty-list boundary. If AGE
  rejects the `IN $param` syntax entirely, the alternative single test asserts the
  `:syntax_error` and records P-S5c = NO — the filter fix must then be written to
  whatever AGE accepts. Neither outcome is a defect to fix.

  Scenario 1 (member selection) proves `IN $ids` SELECTS the listed members and
  EXCLUDES the unlisted one; Scenario 2 (empty list) is the non-vacuity / boundary
  control — it proves an empty param yields nothing, which the filter fix must
  handle.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.Cypher.Parameterized
  alias AshAge.Type.Agtype
  alias Ecto.Adapters.SQL

  @cypher "MATCH (n:Node) WHERE n.id IN $ids RETURN n.id AS rid"
  @return_types [{:rid, :agtype}]

  defp run_in(graph, ids) do
    {sql, pg_params} = Parameterized.build(graph, @cypher, %{"ids" => ids}, @return_types)
    SQL.query(TestRepo, sql, pg_params)
  end

  defp reached(rows) do
    rows |> Enum.map(fn [rid] -> Agtype.decode(rid) end) |> Enum.sort()
  end

  test "P-S5c: `n.id IN $ids` selects the listed members (excludes the unlisted)" do
    graph = "itest_probe_s5c_in"

    with_graph(
      graph,
      fn ->
        {:ok, _} =
          cypher_query(
            graph,
            "CREATE (a:Node {id: 'a'}), (b:Node {id: 'b'}), (c:Node {id: 'c'}) RETURN a"
          )

        result = run_in(graph, ["a", "c"])

        assert {:ok, %{rows: rows}} = result,
               "expected AGE to bind `n.id IN $ids` with a JSON-list param (P-S5c = YES); " <>
                 "got #{inspect(result)}. If this is " <>
                 "{:error, %Postgrex.Error{postgres: %{code: :syntax_error}}}, AGE rejects the " <>
                 "`IN $param` shape (P-S5c = NO) and the In-filter fix must be written to " <>
                 "whatever AGE accepts."

        # PASS => `IN $ids` selects exactly the listed members; `b` is excluded.
        assert reached(rows) == ["a", "c"]
      end,
      vlabels: ["Node"]
    )
  end

  test "P-S5c: empty-list param returns nothing (non-vacuity / boundary)" do
    graph = "itest_probe_s5c_in_empty"

    with_graph(
      graph,
      fn ->
        {:ok, _} =
          cypher_query(
            graph,
            "CREATE (a:Node {id: 'a'}), (b:Node {id: 'b'}), (c:Node {id: 'c'}) RETURN a"
          )

        result = run_in(graph, [])

        assert {:ok, %{rows: rows}} = result,
               "expected AGE to accept an empty-list `IN $ids` param and return nothing; " <>
                 "got #{inspect(result)}. If AGE errors specifically on an EMPTY-list IN param, " <>
                 "the In-filter fix must guard empty lists — record the exact error here."

        # PASS => an empty param matches nothing (the fix's empty-list boundary).
        assert reached(rows) == []
      end,
      vlabels: ["Node"]
    )
  end
end
