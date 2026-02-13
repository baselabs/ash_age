defmodule AshAge do
  @moduledoc """
  Ash Framework DataLayer for Apache AGE graph database.

  ## Setup

  ### 1. Register Postgrex Types

  Create a Postgrex types module so AGE's `agtype` is understood by Ecto:

      defmodule MyApp.PostgrexTypes do
        Postgrex.Types.define(
          MyApp.PostgrexTypes,
          [AshAge.Type.Agtype.Extension] ++ Ecto.Adapters.Postgres.extensions(),
          []
        )
      end

  Then reference it in your Repo config:

      config :my_app, MyApp.Repo,
        types: MyApp.PostgrexTypes

  ### 2. Configure the Repo

  Add the AGE session hook so each connection sets the search path and loads AGE:

      config :my_app, MyApp.Repo,
        after_connect: {AshAge.Session, :setup, []},
        types: MyApp.PostgrexTypes

  ### 3. Create an AGE Migration

  Generate a migration with `mix ash_age.gen.migration`, or write one manually:

      defmodule MyApp.Repo.Migrations.CreateAgeGraph do
        use Ecto.Migration
        import AshAge.Migration

        def up do
          create_age_graph("my_graph")
          create_vertex_label("my_graph", "Entity")
        end

        def down do
          drop_age_graph("my_graph")
        end
      end

  ### 4. Define Ash Resources

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
      end

  ## Mix Tasks

  - `mix ash_age.install` — Print setup instructions
  - `mix ash_age.gen.migration` — Generate an AGE migration
  - `mix ash_age.verify` — Verify AGE database configuration

  ## Modules

  - `AshAge.DataLayer` — The Ash DataLayer implementation
  - `AshAge.Session` — Connection session setup
  - `AshAge.Migration` — Migration helpers
  - `AshAge.Graph` — Graph management utilities
  """
end
