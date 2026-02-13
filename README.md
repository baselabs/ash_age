# ash_age

> **⚠️ AI-Generated Code - Use at Your Own Risk**
>
> This package was initially created using AI tools as part of a larger project
> integration effort. While functional, it may not reflect production-ready
> standards or best practices for a standalone library.
>
> **Use this code at your own discretion.** Review it carefully before
> using in production. Pull requests and contributions to improve the
> implementation and documentation are welcome.

Ash DataLayer for Apache AGE graph database.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ash_age, "~> 0.1.0"}
  ]
end
```

## Usage

See `lib/ash_age.ex` for full documentation.

### Quick Start

1. Ensure Apache AGE extension is installed in PostgreSQL

2. Register Postgrex types for AGE's `agtype`:

```elixir
defmodule MyApp.PostgrexTypes do
  Postgrex.Types.define(
    MyApp.PostgrexTypes,
    [AshAge.Postgrex.AgtypeExtension] ++ Ecto.Adapters.Postgres.extensions(),
    []
  )
end
```

3. Configure your Repo with the AGE session hook and types module:

```elixir
config :my_app, MyApp.Repo,
  after_connect: {AshAge.Session, :setup, []},
  types: MyApp.PostgrexTypes
```

This sets `search_path` to `public, ag_catalog, "$user"` and loads the AGE
extension on each connection. (`public` must be first to prevent shadowing
Ecto's `schema_migrations` table.)

4. Create an AGE graph via migration:

```elixir
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
```

5. Define Ash resources using AshAge.DataLayer:

```elixir
defmodule MyApp.MyEntity do
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
    attribute :tenant_id, :uuid, allow_nil?: false
    attribute :label, :string, allow_nil?: false
    attribute :properties, :map, default: %{}
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end
end
```

## Mix Tasks

- **`mix ash_age.install`** — Print step-by-step setup instructions
- **`mix ash_age.gen.migration NAME`** — Generate a timestamped AGE migration
- **`mix ash_age.verify`** — Verify AGE extension, search_path, and graph existence

## Development

```bash
cd ash_age
mix deps.get
mix test
mix format
mix credo --strict
```

## Documentation

- **CONTRIBUTING.md** — Contribution guidelines
- **LICENSE** — MIT License
- **usage-rules.md** — AI agent usage patterns (via `usage_rules` package)

## License

MIT
