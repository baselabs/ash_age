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

  describe "provision_tenant/3 identifier validation" do
    test "rejects an invalid graph name before any DDL" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.provision_tenant(AshAge.TestRepo, "has-a-hyphen", vlabels: ["Doc"])
      end
    end

    test "rejects an invalid vertex label" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.provision_tenant(AshAge.TestRepo, "good_graph", vlabels: ["Bad-Label"])
      end
    end

    test "rejects an invalid edge label" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.provision_tenant(AshAge.TestRepo, "good_graph", elabels: ["Bad-Label"])
      end
    end
  end

  describe "validate_guc!/1" do
    test "accepts a namespaced (dotted) custom GUC name" do
      assert AshAge.Migration.validate_guc!("ash_age.tenant_id") == "ash_age.tenant_id"
      assert AshAge.Migration.validate_guc!("app.tenant") == "app.tenant"
      assert AshAge.Migration.validate_guc!("a_b.c_d1") == "a_b.c_d1"
    end

    test "rejects a bare (non-namespaced) name — Postgres custom GUCs require a dot" do
      assert_raise ArgumentError, ~r/invalid GUC name/, fn ->
        AshAge.Migration.validate_guc!("tenant_id")
      end
    end

    test "rejects injection / whitespace / multi-dot" do
      for bad <- ["ash_age.tenant'; DROP", "ash age.t", "a.b.c", "ash_age.", ".tenant", ""] do
        assert_raise ArgumentError, ~r/invalid GUC name/, fn ->
          AshAge.Migration.validate_guc!(bad)
        end
      end
    end
  end
end
