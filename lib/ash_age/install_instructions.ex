defmodule AshAge.InstallInstructions do
  @moduledoc false
  # The manual setup instructions shared by `mix ash_age.install`'s two
  # branches (Igniter-writing and print-only) — one text, one owner.

  def render do
    """
    #{header()}

    #{step_0_database()}

    #{step_1_postgrex_types()}

    #{step_2_repo_config()}

    #{step_3_migration()}

    #{step_4_resource()}

    #{step_5_verify()}
    """
    |> String.trim()
  end

  defp header do
    """
    ============================================================
    ash_age Setup Instructions
    ============================================================\
    """
  end

  defp step_0_database do
    """
    Step 0: A PostgreSQL Server with Apache AGE
    ────────────────────────────────────────────

    ash_age needs PostgreSQL 16 + the Apache AGE extension. The quickest
    local server (the ash_age repo ships this compose file — any
    apache/age release_PG16 image works):

        services:
          age:
            image: apache/age:release_PG16_1.6.0
            ports: ["5462:5432"]
            environment:
              POSTGRES_USER: postgres
              POSTGRES_PASSWORD: postgres
              POSTGRES_DB: my_app_test

    Then point your repo config at it. NOTE: the image creates the AGE
    extension only in POSTGRES_DB at init; create it yourself elsewhere:

        CREATE EXTENSION age;  -- as a superuser, once per database\
    """
  end

  defp step_1_postgrex_types do
    """
    Step 1: Register Postgrex Types
    ────────────────────────────────

    Create a Postgrex types module (e.g., lib/my_app/postgrex_types.ex):

        # Postgrex.Types.define/3 defines the module itself — call it at the top
        # level of the file (no `defmodule` wrapper of the same name).
        Postgrex.Types.define(
          MyApp.PostgrexTypes,
          [AshAge.Postgrex.AgtypeExtension] ++ Ecto.Adapters.Postgres.extensions(),
          []
        )\
    """
  end

  defp step_2_repo_config do
    """
    Step 2: Configure Your Repo
    ────────────────────────────

    In config/config.exs (or runtime.exs), add both the types module
    and the after_connect hook:

        config :my_app, MyApp.Repo,
          after_connect: {AshAge.Session, :setup, []},
          types: MyApp.PostgrexTypes

        # ash >= 3.33 refuses to compile :string constraints until the
        # counting basis is explicit (ash_age itself uses :codepoints):
        config :ash, default_string_length_count: :codepoints

    The after_connect hook sets the search_path to include ag_catalog
    and loads the AGE extension on each new connection.\
    """
  end

  defp step_3_migration do
    """
    Step 3: Generate an AGE Migration
    ──────────────────────────────────

    Run:

        $ mix ash_age.gen.migration create_my_graph

    Or create one manually:

        defmodule MyApp.Repo.Migrations.CreateMyGraph do
          use Ecto.Migration
          import AshAge.Migration

          def up do
            create_age_graph("my_graph")
            create_vertex_label("my_graph", "Entity")
            create_edge_label("my_graph", "RELATES_TO")
            create_vertex_index("my_graph", "Entity", "tenant_id")
          end

          def down do
            drop_age_graph("my_graph")
          end
        end

    Then run: mix ecto.migrate\
    """
  end

  defp step_4_resource do
    """
    Step 4: Define an Ash Resource
    ──────────────────────────────

        defmodule MyApp.Entity do
          use Ash.Resource,
            domain: MyApp.Domain,
            data_layer: AshAge.DataLayer

          age do
            graph :my_graph
            repo MyApp.Repo
            label :Entity
          end

          attributes do
            uuid_primary_key :id
            attribute :name, :string, allow_nil?: false
            attribute :properties, :map, default: %{}
          end

          actions do
            defaults [:read, :create, :update, :destroy]
          end
        end\
    """
  end

  defp step_5_verify do
    """
    Step 5: Verify Your Setup
    ─────────────────────────

    After running the migration, verify everything is configured:

        $ mix ash_age.verify
        $ mix ash_age.verify --graph my_graph

    This checks that AGE is installed, the search_path is correct,
    and (optionally) that your graph exists.
    ============================================================\
    """
  end
end
