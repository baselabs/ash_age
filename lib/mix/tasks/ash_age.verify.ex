defmodule Mix.Tasks.AshAge.Verify do
  @shortdoc "Verifies AGE database configuration"

  @moduledoc """
  Verifies that Apache AGE is properly configured in your database.

      $ mix ash_age.verify

  Connects to the database and checks:

  1. The AGE extension is installed
  2. The search_path includes `ag_catalog`
  3. (Optional) A specific graph exists

  ## Options

  - `-r`, `--repo` — The repo to verify against
  - `-g`, `--graph` — A graph name to check for existence

  ## Examples

      $ mix ash_age.verify
      $ mix ash_age.verify --graph my_graph
      $ mix ash_age.verify -r MyApp.Repo -g my_graph
  """

  use Mix.Task

  alias Ecto.Adapters.SQL

  @impl Mix.Task
  def run(args) do
    {opts, _parsed} = parse_args!(args)

    repos = Mix.Ecto.parse_repo(args)
    repo = List.first(repos)
    Mix.Ecto.ensure_repo(repo, args)

    Mix.shell().info("Verifying AGE configuration for #{inspect(repo)}...\n")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        results = [
          check_age_extension(repo),
          check_search_path(repo),
          check_graph(repo, opts[:graph])
        ]

        failures = Enum.count(results, &(&1 == :error))

        Mix.shell().info("")

        if failures > 0 do
          Mix.shell().error("#{failures} check(s) failed. See above for details.")
        else
          Mix.shell().info("All checks passed!")
        end
      end)
  end

  @doc false
  def parse_args!(args) do
    OptionParser.parse!(args,
      strict: [repo: :string, graph: :string],
      aliases: [r: :repo, g: :graph]
    )
  end

  defp check_age_extension(repo) do
    query = """
    SELECT EXISTS (
      SELECT 1 FROM pg_extension WHERE extname = 'age'
    )
    """

    case SQL.query(repo, query, []) do
      {:ok, %{rows: [[true]]}} ->
        Mix.shell().info("  ✓ AGE extension is installed")
        :ok

      _ ->
        Mix.shell().error("  ✗ AGE extension is NOT installed")

        Mix.shell().info("    Run: CREATE EXTENSION IF NOT EXISTS age; in your database")

        :error
    end
  end

  defp check_search_path(repo) do
    case SQL.query(repo, "SHOW search_path", []) do
      {:ok, %{rows: [[path]]}} ->
        if String.contains?(path, "ag_catalog") do
          Mix.shell().info("  ✓ search_path includes ag_catalog (#{path})")
          :ok
        else
          Mix.shell().error("  ✗ search_path does NOT include ag_catalog (#{path})")

          Mix.shell().info(
            "    Add to your Repo config: after_connect: {AshAge.Session, :setup, []}"
          )

          :error
        end

      {:error, reason} ->
        Mix.shell().error("  ✗ Could not check search_path: #{inspect(reason)}")
        :error
    end
  end

  defp check_graph(_repo, nil), do: :ok

  defp check_graph(repo, graph_name) do
    AshAge.Migration.validate_identifier!(graph_name)

    if AshAge.Graph.exists?(repo, graph_name) do
      Mix.shell().info("  ✓ Graph #{inspect(graph_name)} exists")
      :ok
    else
      Mix.shell().error("  ✗ Graph #{inspect(graph_name)} does NOT exist")
      Mix.shell().info("    Create it via migration: create_age_graph(#{inspect(graph_name)})")
      :error
    end
  end
end
