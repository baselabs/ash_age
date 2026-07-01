defmodule AshAge.Cypher.ParameterizedTest do
  use ExUnit.Case, async: true

  alias AshAge.Cypher.Parameterized

  describe "build/3" do
    test "wraps cypher for AGE with a JSON params argument" do
      {sql, params} = Parameterized.build(:my_graph, "MATCH (n) RETURN n", %{"a" => 1})

      assert sql ==
               "SELECT * FROM ag_catalog.cypher('my_graph', $$ MATCH (n) RETURN n $$, $1) AS (v agtype)"

      assert params == [Jason.encode!(%{"a" => 1})]
    end

    test "accepts a string graph name" do
      {sql, _} = Parameterized.build("my_graph", "RETURN 1", %{})
      assert sql =~ "ag_catalog.cypher('my_graph'"
    end

    test "rejects an invalid graph name (SQL string breakout)" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        Parameterized.build("g'); DROP TABLE users; --", "RETURN 1", %{})
      end
    end

    test "rejects a graph name with a quote" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        Parameterized.build("my'graph", "RETURN 1", %{})
      end
    end

    # Defense-in-depth: any identifier that slipped upstream validation and
    # carried a `$$` sequence would break out of AGE's dollar-quoted cypher body.
    test "rejects a cypher body containing $$ (dollar-quote breakout)" do
      assert_raise ArgumentError, ~r/\$\$/, fn ->
        Parameterized.build(:g, "RETURN 1 $$, 'x') AS (v agtype); DROP", %{})
      end
    end

    test "supports custom return type columns" do
      {sql, _} =
        Parameterized.build(:g, "MATCH (n)-[e]->() RETURN n, e", %{}, n: :agtype, e: :agtype)

      assert sql =~ "AS (n agtype, e agtype)"
    end
  end

  describe "build_static/2" do
    test "omits the params argument entirely" do
      {sql, params} = Parameterized.build_static(:my_graph, "RETURN 1")

      assert sql ==
               "SELECT * FROM ag_catalog.cypher('my_graph', $$ RETURN 1 $$) AS (v agtype)"

      assert params == []
    end

    test "rejects an invalid graph name" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        Parameterized.build_static("bad graph", "RETURN 1")
      end
    end

    test "rejects a cypher body containing $$" do
      assert_raise ArgumentError, ~r/\$\$/, fn ->
        Parameterized.build_static(:g, "RETURN 1 $$ ')")
      end
    end
  end
end
