defmodule AshAge.Integration.Probes.UnwindOrderProbeTest do
  @moduledoc """
  Probe P4a (gates S4 R3). Does `UNWIND $rows AS row CREATE (n:L) SET n.k = row.k
  RETURN n` return rows in INPUT order? `bulk_create/3` pairs returned records to
  input changesets by POSITION (Ash's after_action pairing), so order must hold.
  If this flips, `bulk_create` must fall back to per-record for after_action-bearing
  batches.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.Type.Agtype

  test "P4a: UNWIND ... RETURN preserves input order" do
    with_graph(
      "itest_probe_p4a",
      fn ->
        rows = for i <- 1..20, do: %{"idx" => i}
        cypher = "UNWIND $rows AS row CREATE (n:Ord) SET n.idx = row.idx RETURN n"

        {:ok, %{rows: returned}} = cypher_query("itest_probe_p4a", cypher, %{"rows" => rows})

        # Agtype.decode/1 returns a %AshAge.Type.Vertex{} struct whose `.properties`
        # is the property map (verified: lib/type/agtype.ex:49 `properties: data["properties"]`).
        idxs =
          Enum.map(returned, fn [vtext] ->
            vtext |> Agtype.decode() |> Map.fetch!(:properties) |> Map.fetch!("idx")
          end)

        assert idxs == Enum.to_list(1..20),
               "UNWIND did not preserve input order: #{inspect(idxs)}. " <>
                 "bulk_create must fall back to per-record for after_action-bearing batches."
      end,
      vlabels: ["Ord"]
    )
  end
end
