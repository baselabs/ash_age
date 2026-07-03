defmodule AshAge.NotebookRunnerTest do
  use ExUnit.Case, async: true

  # Load the runner module WITHOUT executing a notebook: the script auto-runs only
  # when System.argv() contains a .livemd path, which it never does under `mix test`.
  Code.require_file(Path.join(File.cwd!(), "scripts/run_notebook.exs"))

  alias AshAge.NotebookRunner

  @sample """
  # A notebook

  Prose before code.

  <<FENCE>>elixir
  Mix.install([{:ash_age, "~> 1.0"}])
  <<FENCE>>

  More prose.

  <<FENCE>>elixir
  x = 1 + 1
  <<FENCE>>

  <<FENCE>>
  not elixir, ignored
  <<FENCE>>
  """

  # Build the sample with real triple-backtick fences at runtime so this test file
  # itself contains no nested code fence.
  defp sample, do: String.replace(@sample, "<<FENCE>>", String.duplicate("`", 3))

  test "extract_cells returns only elixir cells, in order" do
    assert NotebookRunner.extract_cells(sample()) == [
             ~s|Mix.install([{:ash_age, "~> 1.0"}])|,
             "x = 1 + 1"
           ]
  end

  test "apply_source_override with nil leaves cells unchanged" do
    cells = [~s|Mix.install([{:ash_age, "~> 1.0"}])|]
    assert NotebookRunner.apply_source_override(cells, nil) == cells
  end

  test "apply_source_override rewrites the ash_age dep to a local path" do
    cells = [~s|Mix.install([{:ash_age, "~> 1.0"}])|]

    assert [~s|Mix.install([{:ash_age, path: "/repo"}])|] =
             NotebookRunner.apply_source_override(cells, "/repo")
  end

  test "apply_source_override raises when override requested but no ash_age dep present" do
    assert_raise RuntimeError, ~r/no cell declares an :ash_age dependency/, fn ->
      NotebookRunner.apply_source_override(["IO.puts(:hi)"], "/repo")
    end
  end

  test "run_cells threads the binding between cells (Livebook semantics)" do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert NotebookRunner.run_cells(["x = 21", "Process.put(:nb_threaded, x * 2)"]) == :ok
    end)

    # `x` from cell 1 was visible in cell 2 -> the binding threaded through. If
    # run_cells reset to a fresh `[]` binding per cell, cell 2 would raise a
    # CompileError on the undefined `x` and this test would go red.
    assert Process.get(:nb_threaded) == 42
  end

  test "run_cells raises on the first failing cell (drift guard fails loud)" do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      # A raising cell must propagate as a raise (-> non-zero script exit). If the
      # runner swallowed cell errors, this assert_raise would go red.
      assert_raise RuntimeError, fn -> NotebookRunner.run_cells([~s|raise "boom"|]) end
    end)
  end
end
