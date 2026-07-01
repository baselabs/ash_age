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
end
