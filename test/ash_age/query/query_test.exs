defmodule AshAge.QueryTest do
  use ExUnit.Case, async: true

  alias AshAge.Query

  defp query(fields \\ []) do
    struct(%Query{resource: __MODULE__, graph: :g, label: :Person, repo: __MODULE__}, fields)
  end

  describe "to_cypher/1" do
    test "builds a MATCH ... RETURN for a bare query" do
      {cypher, params} = Query.to_cypher(query())
      assert cypher == "MATCH (n:Person) RETURN n"
      assert params == %{}
    end

    test "renders a preset WHERE filter clause" do
      {cypher, _} = Query.to_cypher(query(filters: ["n.age > $param1"]))
      assert cypher == "MATCH (n:Person) WHERE n.age > $param1 RETURN n"
    end

    test "renders ORDER BY with direction" do
      {cypher, _} = Query.to_cypher(query(sort: [{:name, :asc}, {:age, :desc}]))
      assert cypher =~ "ORDER BY n.name ASC, n.age DESC"
    end

    test "renders SKIP and LIMIT for integer offset/limit" do
      {cypher, _} = Query.to_cypher(query(offset: 5, limit: 10))
      assert cypher =~ "SKIP 5"
      assert cypher =~ "LIMIT 10"
    end

    # Defense-in-depth: label feeds the cypher body; a non-identifier could
    # inject Cypher or break dollar-quoting.
    test "rejects a non-identifier label" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        Query.to_cypher(query(label: "Person) DETACH DELETE (n"))
      end
    end

    test "rejects a non-identifier sort field" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        Query.to_cypher(query(sort: [{:"name; DROP", :asc}]))
      end
    end

    test "rejects a non-integer limit" do
      assert_raise ArgumentError, ~r/limit/, fn ->
        Query.to_cypher(query(limit: "10; MATCH (x) DETACH DELETE x"))
      end
    end

    test "rejects a non-integer offset" do
      assert_raise ArgumentError, ~r/offset/, fn ->
        Query.to_cypher(query(offset: "5 OR 1=1"))
      end
    end

    test "rejects a negative limit" do
      assert_raise ArgumentError, ~r/limit/, fn ->
        Query.to_cypher(query(limit: -1))
      end
    end
  end

  describe "add_param/2" do
    test "assigns sequential $paramN references" do
      {q1, ref1} = Query.add_param(query(), "a")
      {q2, ref2} = Query.add_param(q1, "b")

      assert ref1 == "$param1"
      assert ref2 == "$param2"
      assert q2.params == %{"param1" => "a", "param2" => "b"}
    end

    test "skips a $paramN key already taken (no clobber on the seeded scoping path)" do
      # On update/destroy, changeset_where seeds the params map with SET/match
      # keys before translating changeset.filter. If a seeded key is literally
      # `param2` (e.g. an attribute named `param2`), the counter lands on it and
      # must SKIP, not overwrite the seeded value with the filter-scoping param.
      seeded = %{query() | params: %{"param2" => "seeded"}}
      {q, ref} = Query.add_param(seeded, "new")

      assert ref == "$param3"
      assert q.params == %{"param2" => "seeded", "param3" => "new"}
    end
  end

  describe "update_cypher/3" do
    test "a sorted+limited query emits ORDER BY before LIMIT (deterministic slice)" do
      # Cross-vendor closeout finding: SKIP/LIMIT without ORDER BY selected an
      # arbitrary slice. The sort must precede SKIP/LIMIT so a sorted+limited
      # bulk_update updates the deterministically-first N rows.
      q = query(sort: [{:count, :desc}], limit: 2)
      {cypher, _} = Query.update_cypher(q, :Person, "n.`name` = $name")

      assert cypher =~ "WITH n ORDER BY n.count DESC LIMIT 2"
      assert cypher =~ "SET n.`name` = $name"
    end

    test "a no-sort limited query omits ORDER BY" do
      q = query(limit: 5)
      {cypher, _} = Query.update_cypher(q, :Person, "n.`name` = $name")
      refute cypher =~ "ORDER BY"
      assert cypher =~ "WITH n LIMIT 5"
    end

    test "a sorted+limited+offset query emits ORDER BY between SKIP and LIMIT" do
      q = query(sort: [{:count, :asc}], offset: 3, limit: 2)
      {cypher, _} = Query.update_cypher(q, :Person, "n.`name` = $name")
      assert cypher =~ "WITH n ORDER BY n.count ASC SKIP 3 LIMIT 2"
    end

    test "an unbounded query (no limit/offset) is a plain SET ... RETURN" do
      {cypher, _} = Query.update_cypher(query(), :Person, "n.`name` = $name")
      assert cypher == "MATCH (n:Person) SET n.`name` = $name RETURN n"
    end
  end
end
