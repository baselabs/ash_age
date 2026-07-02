defmodule AshAge.CypherTest do
  # No DB. These unit-test only the PURE seams of the raw-Cypher hatch:
  #   * the static-vs-param build branch, via `AshAge.Cypher.Parameterized`
  #     directly (empty params -> build_static/3, no $1; non-empty -> build/4, $1);
  #   * the `%{column => decoded}` row shape, via `AshAge.decode_cypher_row/2`.
  # `AshAge.cypher/5`'s DB-touching path — branch selection, `SQL.query`,
  # `row_count`, and the error -> redacted `QueryFailed` mapping — needs a live
  # repo and is exercised in Task 7's integration test (test/integration/raw_cypher_test.exs).
  use ExUnit.Case, async: true

  alias AshAge.Cypher.Parameterized
  alias AshAge.Type.Vertex

  test "static branch omits the params arg for empty params (AGE rejects NULL 3rd arg)" do
    # Assert build path: empty params -> Parameterized.build_static/3.
    {sql, pg_params} =
      Parameterized.build_static("g", "MATCH (n) RETURN n", [{:n, :agtype}])

    assert pg_params == []
    assert sql =~ "AS (n agtype)"
  end

  test "param branch encodes params as the JSON $1 arg" do
    {sql, [json]} =
      Parameterized.build(
        "g",
        "MATCH (n) WHERE n.id = $id RETURN n",
        %{"id" => "x"},
        [{:n, :agtype}]
      )

    assert sql =~ "$1"
    assert json == ~s({"id":"x"})
  end

  test "decode_row builds a %{col => decoded} map from a raw agtype row" do
    row = [~s({"id": 1, "label": "N", "properties": {"id": "x"}}::vertex)]

    assert %{n: %Vertex{properties: %{"id" => "x"}}} =
             AshAge.decode_cypher_row(row, [{:n, :agtype}])
  end

  test "decode_row keeps N columns keyed by return_types names" do
    row = [
      ~s("scalar"),
      ~s({"id": 2, "label": "E", "start_id": 1, "end_id": 3, "properties": {}}::edge)
    ]

    decoded = AshAge.decode_cypher_row(row, [{:v, :agtype}, {:e, :agtype}])
    assert decoded.v == "scalar"
    assert decoded.e.__struct__ == AshAge.Type.Edge
  end

  # The injection/breakout guards live in Parameterized; these pin that the public
  # cypher/5 surface actually routes through them (raises BEFORE any SQL.query, so
  # no DB needed). Goes red if cypher/5 ever bypasses the validating builder.
  test "cypher/5 rejects a $$-breakout body at the public surface (param branch)" do
    assert_raise ArgumentError, ~r/\$\$/, fn ->
      AshAge.cypher(:unused_repo, "g", "RETURN 1 $$ ')", %{"a" => 1}, [{:n, :agtype}])
    end
  end

  test "cypher/5 rejects an invalid graph identifier at the public surface (static branch)" do
    assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
      AshAge.cypher(:unused_repo, "bad graph!", "RETURN 1", %{}, [{:n, :agtype}])
    end
  end

  test "cypher/5 rejects an invalid return-type column at the public surface" do
    assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
      AshAge.cypher(:unused_repo, "g", "RETURN 1", %{}, [{:"n); DROP; --", :agtype}])
    end
  end
end
