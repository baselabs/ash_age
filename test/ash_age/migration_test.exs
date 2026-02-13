defmodule AshAge.MigrationTest do
  use ExUnit.Case, async: true

  describe "validate_identifier!/1" do
    test "accepts valid identifiers" do
      assert AshAge.Migration.validate_identifier!("my_graph") == "my_graph"
      assert AshAge.Migration.validate_identifier!("Entity") == "Entity"
      assert AshAge.Migration.validate_identifier!("RELATES_TO") == "RELATES_TO"
      assert AshAge.Migration.validate_identifier!("_private") == "_private"
      assert AshAge.Migration.validate_identifier!("a") == "a"
      assert AshAge.Migration.validate_identifier!("graph123") == "graph123"
    end

    test "accepts atom identifiers" do
      assert AshAge.Migration.validate_identifier!(:my_graph) == "my_graph"
      assert AshAge.Migration.validate_identifier!(:Entity) == "Entity"
    end

    test "rejects identifiers starting with a number" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.validate_identifier!("123graph")
      end
    end

    test "rejects identifiers with spaces" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.validate_identifier!("my graph")
      end
    end

    test "rejects identifiers with special characters" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.validate_identifier!("my-graph")
      end
    end

    test "rejects empty string" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.validate_identifier!("")
      end
    end

    test "rejects SQL injection attempts" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.validate_identifier!("graph'; DROP TABLE users; --")
      end
    end
  end

  describe "create_age_graph/1" do
    test "rejects invalid graph names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_age_graph("bad name!")
      end
    end
  end

  describe "create_vertex_label/2" do
    test "rejects invalid graph names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_vertex_label("bad name", "Label")
      end
    end

    test "rejects invalid label names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_vertex_label("graph", "bad label")
      end
    end
  end

  describe "create_edge_label/2" do
    test "rejects invalid graph names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_edge_label("bad name", "Label")
      end
    end

    test "rejects invalid label names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_edge_label("graph", "bad-label")
      end
    end
  end

  describe "create_vertex_index/3" do
    test "rejects invalid graph names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_vertex_index("bad name", "Label", "prop")
      end
    end

    test "rejects invalid label names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_vertex_index("graph", "bad label", "prop")
      end
    end

    test "rejects invalid property names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_vertex_index("graph", "Label", "bad prop")
      end
    end
  end

  describe "create_edge_index/3" do
    test "rejects invalid identifiers" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.create_edge_index("bad name", "Label", "prop")
      end
    end
  end

  describe "drop_age_graph/1" do
    test "rejects invalid graph names" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.drop_age_graph("bad name!")
      end
    end
  end
end
