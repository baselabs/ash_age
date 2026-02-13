defmodule Mix.Tasks.AshAge.Gen.Migration do
  @shortdoc "Generates an AGE migration"

  @moduledoc """
  Generates a timestamped Ecto migration with Apache AGE boilerplate.

      $ mix ash_age.gen.migration NAME

  The generated migration uses `up/down` (not `change`) because AGE
  `execute/1` calls are not reversible.

  ## Arguments

  - `NAME` — The migration name in snake_case (e.g., `create_my_graph`)

  ## Options

  - `-r`, `--repo` — The repo to generate the migration for
  - `--migrations-path` — Custom path for the migration file

  ## Examples

      $ mix ash_age.gen.migration create_my_graph
      $ mix ash_age.gen.migration add_person_label -r MyApp.Repo
  """

  use Mix.Task

  import Mix.Generator
  import Mix.Ecto

  @impl Mix.Task
  def run(args) do
    no_umbrella!("ash_age.gen.migration")

    {opts, parsed} =
      OptionParser.parse!(args,
        strict: [repo: :string, migrations_path: :string],
        aliases: [r: :repo]
      )

    [name] = validate_args!(parsed)
    validate_migration_name!(name)

    repos = parse_repo(args)
    repo = List.first(repos)
    ensure_repo(repo, args)

    path = opts[:migrations_path] || source_repo_priv(repo, "migrations")
    check_for_duplicate!(path, name)

    file =
      Path.join(path, "#{timestamp()}_#{name}.exs")

    assigns = [mod: Module.concat([repo, Migrations, Macro.camelize(name)])]

    create_file(file, migration_template(assigns))

    if open?(file) do
      Mix.shell().info("""

      Once you have customized the migration, run:

          $ mix ecto.migrate
      """)
    end
  end

  @doc false
  def validate_migration_name!(name) do
    unless name =~ ~r/\A[a-z][a-z0-9_]*\z/ do
      Mix.raise(
        "migration name must be snake_case (lowercase letters, numbers, and underscores, " <>
          "starting with a letter). Got: #{inspect(name)}"
      )
    end
  end

  defp validate_args!([name]) when is_binary(name), do: [name]

  defp validate_args!(_) do
    Mix.raise("""
    expected exactly one argument: the migration name

        mix ash_age.gen.migration NAME

    Example:

        mix ash_age.gen.migration create_my_graph
    """)
  end

  defp check_for_duplicate!(path, name) do
    pattern = Path.join(path, "*_#{name}.exs")

    case Path.wildcard(pattern) do
      [] ->
        :ok

      [existing | _] ->
        Mix.raise(
          "migration #{inspect(name)} already exists at #{existing}. " <>
            "Choose a different name or delete the existing migration."
        )
    end
  end

  defp source_repo_priv(repo, path) do
    priv = Mix.EctoSQL.source_repo_priv(repo)
    Path.join(priv, path)
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"

  embed_template(:migration, """
  defmodule <%= inspect @mod %> do
    use Ecto.Migration
    import AshAge.Migration

    def up do
      # Create the AGE graph
      # create_age_graph("my_graph")

      # Create vertex labels
      # create_vertex_label("my_graph", "MyVertex")

      # Create edge labels
      # create_edge_label("my_graph", "MY_EDGE")

      # Create indexes on vertex properties
      # create_vertex_index("my_graph", "MyVertex", "tenant_id")
    end

    def down do
      # Drop the graph and all its data
      # drop_age_graph("my_graph")
    end
  end
  """)
end
