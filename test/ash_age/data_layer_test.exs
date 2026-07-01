defmodule AshAge.DataLayerTest do
  use ExUnit.Case, async: true

  alias AshAge.DataLayer

  describe "set_clauses/1" do
    test "builds n.key = $key fragments with parameterized values" do
      assert DataLayer.set_clauses(%{"name" => "x", "age" => 1}) in [
               "n.name = $name, n.age = $age",
               "n.age = $age, n.name = $name"
             ]
    end

    test "returns an empty string for no properties" do
      assert DataLayer.set_clauses(%{}) == ""
    end

    test "rejects a property key that is not a valid identifier (injection guard)" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        DataLayer.set_clauses(%{"name = 1 WITH n MATCH (x) DETACH DELETE x //" => "v"})
      end
    end
  end

  describe "can?/2 composite primary key" do
    test "declares composite-primary-key support (required for composite-PK resources to compile)" do
      assert DataLayer.can?(AshAge.DataLayer, :composite_primary_key)
    end
  end

  describe "pk_match_clause/2" do
    test "single :id key is byte-identical to the legacy hardcoded clause (backward compat)" do
      assert DataLayer.pk_match_clause([{:id, "u1"}], %{}) ==
               {"n.id = $match_id", %{"match_id" => "u1"}}
    end

    test "single non-:id key derives the predicate from the actual key name" do
      assert DataLayer.pk_match_clause([{:code, "abc"}], %{}) ==
               {"n.code = $match_code", %{"match_code" => "abc"}}
    end

    test "composite key ANDs both predicates with distinct params, declaration order preserved" do
      assert DataLayer.pk_match_clause([{:tenant_id, "t1"}, {:id, "u1"}], %{}) ==
               {"n.tenant_id = $match_tenant_id AND n.id = $match_id",
                %{"match_tenant_id" => "t1", "match_id" => "u1"}}
    end

    test "renames the match param when it would collide with a reserved (changed-attr) key" do
      assert DataLayer.pk_match_clause([{:id, "u1"}], %{"match_id" => "changed"}) ==
               {"n.id = $match_id_", %{"match_id_" => "u1"}}
    end

    test "rejects a primary-key field that is not a valid AGE identifier (injection guard)" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        DataLayer.pk_match_clause([{String.to_atom("id = 1 //"), "x"}], %{})
      end
    end

    test "raises when the resource declares no primary key (empty match is not valid Cypher)" do
      assert_raise ArgumentError, ~r/requires a primary key/, fn ->
        DataLayer.pk_match_clause([], %{})
      end
    end
  end
end
