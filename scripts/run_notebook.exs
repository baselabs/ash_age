# Executes a Livebook .livemd notebook headless, cell by cell, against a live
# database — the CI drift guard for notebooks/*.livemd. Run:
#
#     elixir scripts/run_notebook.exs notebooks/getting_started.livemd
#
# A .livemd is Markdown whose runnable cells are ```elixir fenced blocks. A
# monolithic concatenation of those cells fails to compile (`require Ash.Query`
# resolves before `Mix.install` runs), so cells are evaluated one at a time with
# Code.eval_string/3, threading the binding between cells (Livebook semantics).
# Note: only the binding is threaded — require/import/alias do NOT persist across
# cells as they do in Livebook, so a notebook run here must keep a macro `require`
# (e.g. `require Ash.Query` for `filter`) in the same cell as its use.
# When ASH_AGE_SRC is set, the ash_age dependency in the Mix.install cell is
# rewritten to that local path so CI tests the working tree, not the published
# release; a requested override that matches no dependency line raises (a silent
# no-op would defeat the drift guard).
defmodule AshAge.NotebookRunner do
  @moduledoc false

  # Three backticks kept as bytes so this source file contains no literal code fence.
  @fence <<96, 96, 96>>

  @doc "Extracts elixir fenced code cells from livemd source, in order."
  def extract_cells(source) when is_binary(source) do
    # Matches a BARE `<fence>elixir` open line only — a trailing space or a
    # Livebook cell annotation would not match and that cell would be skipped.
    open = @fence <> "elixir"

    {cells, _open} =
      source
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {cells, current} ->
        cond do
          is_nil(current) and line == open -> {cells, []}
          not is_nil(current) and line == @fence -> {cells ++ [Enum.join(current, "\n")], nil}
          not is_nil(current) -> {cells, current ++ [line]}
          true -> {cells, current}
        end
      end)

    cells
  end

  @doc """
  Rewrites the ash_age dependency to a local path when `src` is a path string;
  returns cells unchanged when `src` is nil. Raises when `src` is given but no
  cell declares an ash_age dependency (a silent no-op would defeat the CI drift guard).
  """
  def apply_source_override(cells, nil), do: cells

  def apply_source_override(cells, src) when is_binary(src) do
    dep = ~r/\{\s*:ash_age\s*,\s*[^}]*\}/

    {rewritten, count} =
      Enum.map_reduce(cells, 0, fn cell, acc ->
        if Regex.match?(dep, cell) do
          {Regex.replace(dep, cell, "{:ash_age, path: #{inspect(src)}}"), acc + 1}
        else
          {cell, acc}
        end
      end)

    if count == 0 do
      raise "ASH_AGE_SRC=#{src} set but no cell declares an :ash_age dependency to override"
    end

    rewritten
  end

  @doc "Evaluates cells in order, threading the binding between them. Raises on the first failing cell."
  def run_cells(cells) do
    total = length(cells)

    # The threaded binding is the accumulator, not a result we return — the final
    # binding is intentionally discarded (bound to `_`) once every cell has run.
    _final_binding =
      cells
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {cell, idx}, binding ->
        IO.puts(:stderr, "[run_notebook] cell #{idx}/#{total}")
        {_result, new_binding} = Code.eval_string(cell, binding)
        new_binding
      end)

    :ok
  end

  @doc "Reads, overrides, and runs a notebook file."
  def run(path, src) do
    path
    |> File.read!()
    |> extract_cells()
    |> apply_source_override(src)
    |> run_cells()
  end
end

# Auto-run only when invoked as a script with a .livemd argument, so `mix test`
# can Code.require_file this module without executing a notebook.
case Enum.find(System.argv(), &String.ends_with?(&1, ".livemd")) do
  nil -> :ok
  path -> AshAge.NotebookRunner.run(path, System.get_env("ASH_AGE_SRC"))
end
