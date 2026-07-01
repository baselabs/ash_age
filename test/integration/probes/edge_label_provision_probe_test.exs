defmodule AshAge.Integration.Probes.EdgeLabelProvisionProbeTest do
  @moduledoc """
  Probe P4 (gates S4 R2). Does AGE auto-create an edge label on
  `CREATE (a)-[:Unprovisioned]->(b)` in a graph provisioned with ONLY vertex
  labels?

  CONFIRMED (2026-07-01, live AGE, unboxed connection): YES — AGE silently
  auto-creates the missing edge label and the CREATE succeeds with
  `{:ok, %Postgrex.Result{num_rows: 1, ...}}`. The design's assumption that
  elabels must be pre-provisioned (R2) is FALSE and must be relaxed: no
  provisioning requirement exists for edge labels, and the friendly
  missing-label error mapping planned for T4/T5 is unnecessary (there is no
  missing-label error to map). This test pins the confirmed behavior as a
  regression tripwire — if AGE's behavior ever changes to error instead, this
  test will flip red and the provisioning requirement should be reinstated.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  test "P4: CREATE against an unprovisioned edge label auto-creates the elabel (no pre-provisioning required)" do
    with_graph(
      "itest_probe_p4",
      fn ->
        {:ok, _} =
          cypher_query(
            "itest_probe_p4",
            "CREATE (a:Node) SET a.name = $a CREATE (b:Node) SET b.name = $b RETURN a",
            %{"a" => "s", "b" => "d"}
          )

        result =
          cypher_query(
            "itest_probe_p4",
            "MATCH (a:Node), (b:Node) WHERE a.name = $a AND b.name = $b CREATE (a)-[e:Unprovisioned]->(b) RETURN e",
            %{"a" => "s", "b" => "d"}
          )

        # CONFIRMED: {:ok, _} — AGE auto-creates the elabel. If this ever flips
        # to {:error, _}, AGE started enforcing pre-provisioned elabels again —
        # reinstate the R2 provisioning contract and the friendly-error mapping.
        assert match?({:ok, %{num_rows: 1}}, result),
               "expected AGE to auto-create the unprovisioned edge label; got #{inspect(result)}. " <>
                 "If {:error, _}, AGE now requires pre-provisioned elabels — reinstate the R2 provisioning contract."
      end,
      vlabels: ["Node"]
    )
  end
end
