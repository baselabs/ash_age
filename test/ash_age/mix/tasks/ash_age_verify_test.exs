defmodule Mix.Tasks.AshAge.VerifyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshAge.Verify

  describe "parse_args!/1" do
    test "parses --graph option" do
      {opts, _} = Verify.parse_args!(["--graph", "my_graph"])
      assert opts[:graph] == "my_graph"
    end

    test "parses -g shorthand" do
      {opts, _} = Verify.parse_args!(["-g", "my_graph"])
      assert opts[:graph] == "my_graph"
    end

    test "parses --repo option" do
      {opts, _} = Verify.parse_args!(["--repo", "MyApp.Repo"])
      assert opts[:repo] == "MyApp.Repo"
    end

    test "parses -r shorthand" do
      {opts, _} = Verify.parse_args!(["-r", "MyApp.Repo"])
      assert opts[:repo] == "MyApp.Repo"
    end

    test "parses combined options" do
      {opts, _} = Verify.parse_args!(["-r", "MyApp.Repo", "-g", "test_graph"])
      assert opts[:repo] == "MyApp.Repo"
      assert opts[:graph] == "test_graph"
    end

    test "raises on unknown options" do
      assert_raise OptionParser.ParseError, fn ->
        Verify.parse_args!(["--unknown", "value"])
      end
    end
  end

  describe "graph name validation via AshAge.Migration.validate_identifier!/1" do
    test "valid graph names pass" do
      assert AshAge.Migration.validate_identifier!("my_graph") == "my_graph"
    end

    test "invalid graph names raise" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        AshAge.Migration.validate_identifier!("bad graph!")
      end
    end
  end
end
