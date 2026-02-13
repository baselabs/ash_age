defmodule Mix.Tasks.AshAge.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.AshAge.Install

  describe "instructions/0" do
    test "includes Postgrex types step" do
      text = Install.instructions()
      assert text =~ "Postgrex Types"
      assert text =~ "Postgrex.Types.define"
      assert text =~ "AshAge.Type.Agtype.Extension"
    end

    test "includes repo config step" do
      text = Install.instructions()
      assert text =~ "Configure Your Repo"
      assert text =~ "after_connect"
      assert text =~ "AshAge.Session"
      assert text =~ "types: MyApp.PostgrexTypes"
    end

    test "includes migration step" do
      text = Install.instructions()
      assert text =~ "Migration"
      assert text =~ "mix ash_age.gen.migration"
      assert text =~ "create_age_graph"
      assert text =~ "create_vertex_label"
    end

    test "includes resource definition step" do
      text = Install.instructions()
      assert text =~ "Ash Resource"
      assert text =~ "AshAge.DataLayer"
      assert text =~ "age do"
    end

    test "includes verify step" do
      text = Install.instructions()
      assert text =~ "Verify"
      assert text =~ "mix ash_age.verify"
    end
  end
end
