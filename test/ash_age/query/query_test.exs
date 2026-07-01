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
end
