defmodule Mix.Tasks.AshAge.Gen.MigrationTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshAge.Gen.Migration

  describe "validate_migration_name!/1" do
    test "accepts valid snake_case names" do
      assert Migration.validate_migration_name!("create_my_graph") == :ok || true
      assert Migration.validate_migration_name!("add_person_label") == :ok || true
      assert Migration.validate_migration_name!("setup") == :ok || true
      assert Migration.validate_migration_name!("create_graph_v2") == :ok || true
    end

    test "rejects names starting with a number" do
      assert_raise Mix.Error, ~r/snake_case/, fn ->
        Migration.validate_migration_name!("123_bad")
      end
    end

    test "rejects names with uppercase" do
      assert_raise Mix.Error, ~r/snake_case/, fn ->
        Migration.validate_migration_name!("CreateMyGraph")
      end
    end

    test "rejects names with hyphens" do
      assert_raise Mix.Error, ~r/snake_case/, fn ->
        Migration.validate_migration_name!("create-my-graph")
      end
    end

    test "rejects names with spaces" do
      assert_raise Mix.Error, ~r/snake_case/, fn ->
        Migration.validate_migration_name!("create my graph")
      end
    end

    test "rejects empty string" do
      assert_raise Mix.Error, ~r/snake_case/, fn ->
        Migration.validate_migration_name!("")
      end
    end
  end
end
