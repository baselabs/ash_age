defmodule AshAge.Integration.RawCypherTest do
  @moduledoc """
  Live-AGE round-trip coverage for `AshAge.cypher/5`, the raw-Cypher escape
  hatch. Exercises the static (empty-params) and parameterized branches, the
  first live `Type.Edge`/`Type.Path` decode consumers, multi-column shape,
  the aggregate-cell boundary (raw agtype text, not decoded), and error
  redaction (no seeded value leaks into the returned reason).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.Errors.QueryFailed
  alias AshAge.Type.{Edge, Path, Vertex}

  test "RETURN n decodes to a Vertex (static/empty-params branch)" do
    with_graph(
      "itest_s5_raw_vertex",
      fn ->
        {:ok, _} =
          cypher_query("itest_s5_raw_vertex", "CREATE (n:Node {id: 'a'}) RETURN n")

        assert {:ok, [%{n: vertex}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_vertex",
                   "MATCH (n:Node {id: 'a'}) RETURN n",
                   %{},
                   [{:n, :agtype}]
                 )

        assert %Vertex{properties: %{"id" => "a"}} = vertex
      end,
      vlabels: ["Node"]
    )
  end

  test "RETURN r decodes to an Edge (first live Type.Edge consumer)" do
    with_graph(
      "itest_s5_raw_edge",
      fn ->
        {:ok, _} =
          cypher_query(
            "itest_s5_raw_edge",
            "CREATE (a:Node {id: 'a'}), (b:Node {id: 'b'}), (a)-[:LINK]->(b) RETURN a"
          )

        # Fetch the two seeded endpoints' internal ids so we can cross-check the
        # decoded edge points from a -> b (not just that it has the right shape).
        assert {:ok, [%{a: %Vertex{id: a_id, properties: %{"id" => "a"}}, b: %Vertex{id: b_id}}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_edge",
                   "MATCH (a:Node {id: 'a'}), (b:Node {id: 'b'}) RETURN a, b",
                   %{},
                   [{:a, :agtype}, {:b, :agtype}]
                 )

        assert {:ok, [%{r: edge}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_edge",
                   "MATCH (a:Node {id: 'a'})-[r:LINK]->(b:Node {id: 'b'}) RETURN r",
                   %{},
                   [{:r, :agtype}]
                 )

        assert %Edge{label: "LINK", start_id: start_id, end_id: end_id} = edge
        assert is_integer(start_id)
        assert is_integer(end_id)
        # Decode produced coherent linked data: the edge runs from a to b.
        assert start_id != end_id
        assert start_id == a_id
        assert end_id == b_id
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  test "RETURN p decodes to a Path (first live Type.Path consumer)" do
    with_graph(
      "itest_s5_raw_path",
      fn ->
        {:ok, _} =
          cypher_query(
            "itest_s5_raw_path",
            "CREATE (a:Node {id: 'a'}), (b:Node {id: 'b'}), (a)-[:LINK]->(b) RETURN a"
          )

        assert {:ok, [%{p: path}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_path",
                   "MATCH p = (a:Node {id: 'a'})-[:LINK]->(b:Node) RETURN p",
                   %{},
                   [{:p, :agtype}]
                 )

        assert %Path{vertices: [v_a, v_b], edges: [edge]} = path

        # Decode produced coherent linked data, not just correctly-shaped structs:
        # the two vertices carry the seeded properties, and the edge's endpoints
        # line up with those vertices' ids (a -> b).
        assert %Vertex{id: a_id, properties: %{"id" => "a"}} = v_a
        assert %Vertex{id: b_id, properties: %{"id" => "b"}} = v_b
        assert %Edge{label: "LINK", start_id: ^a_id, end_id: ^b_id} = edge
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  test "parameterized round-trip binds via $1 (param branch → Parameterized.build/4)" do
    with_graph(
      "itest_s5_raw_params",
      fn ->
        # A distinctive token (not a common single letter) so the "value binds
        # only via $1, never the body" refute below is a meaningful injection
        # contract, not a coincidental substring miss.
        target_id = "zzq-distinctive-42"

        {:ok, _} =
          cypher_query(
            "itest_s5_raw_params",
            "CREATE (a:Node {id: '#{target_id}'}), (b:Node {id: 'other'}) RETURN a"
          )

        cypher = "MATCH (n:Node) WHERE n.id = $id RETURN n"

        assert {:ok, [%{n: vertex}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_params",
                   cypher,
                   %{"id" => target_id},
                   [{:n, :agtype}]
                 )

        # Returned the node matching the bound id — not the sibling.
        assert %Vertex{properties: %{"id" => ^target_id}} = vertex
        # The distinctive value never appears in the query body itself — it is
        # bound only through the $1 JSON parameter.
        refute cypher =~ target_id
      end,
      vlabels: ["Node"]
    )
  end

  test "RETURN n, m decodes to a uniform %{col => decoded} multi-column shape" do
    with_graph(
      "itest_s5_raw_multicol",
      fn ->
        {:ok, _} =
          cypher_query(
            "itest_s5_raw_multicol",
            "CREATE (n:Node {id: 'a'}), (m:Node {id: 'b'}) RETURN n"
          )

        assert {:ok, [%{n: n_vertex, m: m_vertex}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_multicol",
                   "MATCH (n:Node {id: 'a'}), (m:Node {id: 'b'}) RETURN n, m",
                   %{},
                   [{:n, :agtype}, {:m, :agtype}]
                 )

        assert %Vertex{properties: %{"id" => "a"}} = n_vertex
        assert %Vertex{properties: %{"id" => "b"}} = m_vertex
      end,
      vlabels: ["Node"]
    )
  end

  test "RETURN collect(n) stays raw agtype text at the aggregate boundary" do
    with_graph(
      "itest_s5_raw_aggregate",
      fn ->
        {:ok, _} =
          cypher_query(
            "itest_s5_raw_aggregate",
            "CREATE (n:Node {id: 'a'}), (m:Node {id: 'b'}) RETURN n"
          )

        assert {:ok, [%{agg: agg}]} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_aggregate",
                   "MATCH (n:Node) RETURN collect(n) AS agg",
                   %{},
                   [{:agg, :agtype}]
                 )

        assert is_binary(agg)
        refute match?(%Vertex{}, agg)
      end,
      vlabels: ["Node"]
    )
  end

  test "a malformed query returns a redacted QueryFailed with no leaked seeded value" do
    with_graph(
      "itest_s5_raw_redact",
      fn ->
        secret_id = "super-secret-node-id"

        {:ok, _} =
          cypher_query(
            "itest_s5_raw_redact",
            "CREATE (n:Node {id: '#{secret_id}'}) RETURN n"
          )

        assert {:error, %QueryFailed{} = error} =
                 AshAge.cypher(
                   AshAge.TestRepo,
                   "itest_s5_raw_redact",
                   "MATCH (n:Node {id: '#{secret_id}'}) RETURN no_such_fn(n)",
                   %{},
                   [{:n, :agtype}]
                 )

        message = Exception.message(error)
        refute message =~ secret_id
        refute inspect(error.reason) =~ secret_id
        assert is_binary(error.reason)
        assert error.reason =~ "database error"
      end,
      vlabels: ["Node"]
    )
  end
end
