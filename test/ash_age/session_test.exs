defmodule AshAge.SessionTest do
  use ExUnit.Case, async: true

  describe "setup/1" do
    test "is exported with arity 1" do
      Code.ensure_loaded!(AshAge.Session)
      assert function_exported?(AshAge.Session, :setup, 1)
    end

    test "is callable as an after_connect MFA" do
      # Verifies the MFA tuple shape that Ecto expects for after_connect
      {mod, fun, args} = {AshAge.Session, :setup, []}

      Code.ensure_loaded!(mod)
      assert function_exported?(mod, fun, length(args) + 1)
    end
  end
end
