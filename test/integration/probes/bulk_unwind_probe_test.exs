defmodule AshAge.Integration.Probes.BulkUnwindProbeTest do
  @moduledoc """
  Feasibility probe P1 (gates S4 bulk-create). Asserts the hoped-for capability:
  AGE accepts `UNWIND $rows AS row CREATE (n:Label) SET n.k = row.k`. A failure
  here is a RECORDED result (P1 = no → keep can?(:bulk_create) = false and use
  Ash's default per-record path), not a bug to fix.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  test "P1: AGE accepts UNWIND $rows AS row CREATE (n:Item) SET n.name = row.name" do
    with_graph(
      "itest_probe_p1",
      fn ->
        cypher = "UNWIND $rows AS row CREATE (n:Item) SET n.name = row.name RETURN n"
        params = %{"rows" => [%{"name" => "a"}, %{"name" => "b"}]}

        # PASS => P1 = yes (S4 bulk uses UNWIND). {:error, %Postgrex.Error{}} => P1 = no.
        assert {:ok, %{num_rows: 2}} = cypher_query("itest_probe_p1", cypher, params)
      end,
      vlabels: ["Item"]
    )
  end
end
