defmodule AshAge.Integration.Probes.MissingGraphProbeTest do
  @moduledoc """
  Records AGE's behavior when a Cypher MATCH targets a graph that was never
  provisioned. The `:context` read path relies on this being an ERROR (fail-closed)
  rather than an empty result. If this test goes RED (AGE returns `{:ok, []}`), the
  design's §5.7 contingency applies: add an `AshAge.Graph.exists?/2` guard on the
  `:context` read path so a mis-provisioned tenant surfaces a redacted error instead
  of silently reading empty.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  alias AshAge.DataCase

  test "querying a never-provisioned graph errors (fail-closed), not empty" do
    # A graph name we deliberately never create.
    result = DataCase.cypher_query("mt_missing_graph_probe", "MATCH (n:Ghost) RETURN n")

    assert match?({:error, _}, result),
           "expected AGE to error on a missing graph; got #{inspect(result)}. " <>
             "If this is {:ok, []}, implement the §5.7 exists?/2 read-path guard."
  end
end
