# The installer has two shapes:
#
# - With Igniter loaded (a host app that has igniter — including
#   `mix igniter.install ash_age`), `mix ash_age.install` WRITES the wiring:
#   the Postgrex types module, the Repo's `after_connect`/`types` config, and
#   the ash string-length basis. It never guesses — with zero or multiple
#   `*.Repo` modules it prints the manual steps instead.
# - Without Igniter, the task is the original print-instructions task.
#
# Both branches render the same manual instructions (`instructions/0`), so the
# documented contract and the tests hold either way.
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshAge.Install do
    @shortdoc "Installs ash_age wiring (config + Postgrex types). `mix igniter.install ash_age`"

    @moduledoc """
    #{@shortdoc}

    Writes the standard wiring into your project:

    - `lib/my_app/postgrex_types.ex` — the agtype extension registration
      (created only if absent)
    - `config :my_app, MyApp.Repo, after_connect: {AshAge.Session, :setup, []}, types: ...`
    - `config :ash, default_string_length_count: :codepoints` (required by
      ash >= 3.33)

    Requires exactly one Repo module (a module named `*.Repo`). If your Repo
    is named differently (or you have several), the task prints the manual
    steps instead of guessing.

    ## What it does NOT do

    Database creation or migrations — run `mix ash_age.gen.migration` and
    `mix ecto.migrate` next (the printed next-steps include both, plus how to
    start a local AGE server).
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Config, as: ProjectConfig
    alias Igniter.Project.Module, as: ProjectModule

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = Igniter.Project.Application.app_name(igniter)
      {igniter, repos} = discover_repos(igniter)

      case repos do
        [repo] ->
          igniter
          |> create_types_module(app)
          |> ProjectConfig.configure(
            "config.exs",
            app,
            [repo, :after_connect],
            {AshAge.Session, :setup, []}
          )
          |> ProjectConfig.configure("config.exs", app, [repo, :types], types_module(app))
          |> ProjectConfig.configure(
            "config.exs",
            :ash,
            [:default_string_length_count],
            :codepoints
          )
          |> finish(repo)

        [] ->
          Mix.shell().error("""
          No `*.Repo` module found — ash_age could not guess where to wire
          `after_connect`/`types`. The manual steps:\
          """)

          Mix.shell().info(instructions())
          igniter

        many ->
          Mix.shell().error("""
          Multiple Repo modules found (#{inspect(many)}) — ash_age will not guess.
          The manual steps:\
          """)

          Mix.shell().info(instructions())
          igniter
      end
    end

    @doc false
    # The manual instructions, shared with the no-Igniter fallback branch and
    # pinned by the unit tests.
    def instructions, do: AshAge.InstallInstructions.render()

    defp discover_repos(igniter) do
      # The predicate receives (module_name, zipper); we match on the NAME
      # (a module literally named `*.Repo`) — conservative by design.
      ProjectModule.find_all_matching_modules(igniter, fn module, _zipper ->
        module |> Module.split() |> List.last() == "Repo"
      end)
    end

    defp types_module(app), do: Module.concat([Macro.camelize(to_string(app)), PostgrexTypes])

    defp create_types_module(igniter, app) do
      module = types_module(app)

      Igniter.create_new_file(
        igniter,
        ProjectModule.proper_location(igniter, module),
        types_module_source(module)
      )
    end

    defp types_module_source(module) do
      """
      # Postgrex.Types.define/3 defines the module itself — call it at the top
      # level of the file (no `defmodule` wrapper of the same name).
      Postgrex.Types.define(
        #{inspect(module)},
        [AshAge.Postgrex.AgtypeExtension] ++ Ecto.Adapters.Postgres.extensions(),
        []
      )
      """
    end

    defp finish(igniter, repo) do
      Mix.shell().info("""
      ash_age wiring written:
        - Postgrex types module (agtype registered)
        - #{inspect(repo)}: after_connect + types
        - config :ash, default_string_length_count: :codepoints

      Next:
        1. Start an Apache AGE server — quickest is the ash_age repo's
           compose.yaml (`docker compose up -d`, localhost:5462).
        2. mix ash_age.gen.migration create_my_graph
        3. mix ecto.migrate
        4. mix ash_age.verify
      """)

      igniter
    end
  end
else
  defmodule Mix.Tasks.AshAge.Install do
    @shortdoc "Prints setup instructions for ash_age"

    @moduledoc """
    Prints step-by-step setup instructions for integrating ash_age
    into your application.

        $ mix ash_age.install

    With [Igniter](https://hex.pm/packages/igniter) installed, this task
    instead WRITES the wiring for you (or run `mix igniter.install ash_age`).
    """

    use Mix.Task

    @impl Mix.Task
    def run(_args) do
      Mix.shell().info(instructions())
    end

    @doc false
    def instructions, do: AshAge.InstallInstructions.render()
  end
end
