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
    {:ash_age, "~> 0.2.4"}
  ]
end
```

### Compatibility

Tested against **Apache AGE 1.6.0 on PostgreSQL 16** (the `apache/age:release_PG16_1.6.0`
image, pinned by digest in CI). Other PostgreSQL majors with a matching AGE build are
expected to work but are not covered by CI.

## Usage

See `lib/ash_age.ex` for full documentation.

### Quick Start

1. Ensure Apache AGE extension is installed in PostgreSQL

2. Register Postgrex types for AGE's `agtype`:

```elixir
# Postgrex.Types.define/3 defines the module itself — call it at the top level
# of the file (no `defmodule` wrapper of the same name).
Postgrex.Types.define(
  MyApp.PostgrexTypes,
  [AshAge.Postgrex.AgtypeExtension] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
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

### Edges

Graph edges connect vertices. Define them in the `age` block:

```elixir
age do
  graph :my_graph
  repo MyApp.Repo
  
  edge :related_to do
    label :RELATES_TO
    direction :outgoing
    destination MyApp.RelatedEntity
    properties [:weight]
  end
end
```

Create and destroy edges via changes:

```elixir
actions do
  create :create_with_relation do
    argument :related_id, :uuid
    change {AshAge.Changes.CreateEdge, edge: :related_to, to: :related_id}
  end
  
  destroy :remove_relation do
    argument :related_id, :uuid
    change {AshAge.Changes.DestroyEdge, edge: :related_to, to: :related_id}
  end
end
```

Edges are atomic with their source vertex write, tenant-isolated, and fail closed
on endpoint not found. Edge property values come from same-named action arguments.
See `usage-rules.md` for constraints (single-PK destinations) and direction semantics.

### Traversal

Bounded variable-length graph traversal is an Ash manual relationship via
`AshAge.ManualRelationships.Traverse`:

```elixir
has_many :descendants, MyApp.Node do
  manual {AshAge.ManualRelationships.Traverse,
          edge_label: :LINK, direction: :outgoing, min_depth: 1, max_depth: 3}
end
```

`direction` may be `:outgoing`, `:incoming`, or `:both` (undirected). `max_depth`
is required and bounded (unbounded `*` is forbidden). Loading yields a source-PK-keyed
map of destination records, deduped per source and cardinality-aware, with single or
composite primary keys. Tenancy is fail-closed: `:context` scopes to the per-tenant
graph, and `:attribute` scopes every node on the path by the tenant discriminator (via
a fixed-length UNION expansion, since this AGE build lacks `ALL(nodes(p))`). See
`usage-rules.md` for options and telemetry.

### Raw Cypher

For queries the DSL can't express, `AshAge.cypher/5` runs parameterized Cypher and
decodes each cell:

```elixir
AshAge.cypher(MyApp.Repo, "my_graph",
  "MATCH (n:Person)-[:KNOWS*1..2]->(m) WHERE n.id = $id RETURN m",
  %{"id" => person_id},
  [{:m, :agtype}])
#=> {:ok, [%{m: %AshAge.Type.Vertex{...}}, ...]}
```

Values reach AGE only as `$` params; the `graph` name is identifier-checked. Each cell
decodes to a `%Vertex{}`/`Edge{}`/`Path{}` or a scalar; a bare aggregate (`collect(n)`)
returns as its raw agtype string (use `UNWIND`). The `graph` you pass is the tenant
isolation boundary. See `usage-rules.md` for the full contract.

### Bulk Create

`Ash.bulk_create` is now supported via `UNWIND` grouping. Rows are grouped by
their key-set so sparse rows don't null-fill to match others. Record order is
preserved, and failures are atomic per batch. See `usage-rules.md` for transaction
semantics and tenant handling.

### Multitenancy

Both Ash strategies are supported. **`:attribute`** (one graph, tenant-filtered)
works through Ash core — just declare `multitenancy do strategy :attribute;
attribute :org_id end` (don't list the attribute in `age do skip` or an action's
`accept`). **`:context`** gives graph-per-tenant physical isolation: declare
`strategy :context`, then provision each tenant's graph up front —

```elixir
graph = AshAge.tenant_graph(MyApp.Entity, tenant)
AshAge.Migration.provision_tenant(MyApp.Repo, graph, vlabels: ["Entity"])
```

Tenant/policy filters are enforced on `update`/`destroy` (not just reads). See
`usage-rules.md` for the graph-name encoder, the `tenant_graph` MFA override, and
strategy trade-offs.

For `:attribute` resources, an opt-in `rls_guc` option adds PostgreSQL Row-Level
Security as a DB-enforced read-confidentiality backstop beneath the app-layer tenant
filter (enabled via `AshAge.Migration.enable_tenant_rls/2`). It is read/target-side
only — AGE `cypher()` CREATE bypasses `WITH CHECK` — and requires the app's DB role
to be a non-superuser without `BYPASSRLS`. See the "Multitenancy — DB-enforced RLS"
section of `usage-rules.md` for the full contract.

### Sensitive Data

Classify attributes whose plaintext must never reach the graph; store
app-side-encrypted bytes (AshCloak/Cloak) in `:binary` attributes:

```elixir
age do
  graph :my_graph
  repo MyApp.Repo
  sensitive [:ssn]  # compile-time fail-closed: binary-storage-typed or skipped
end
```

Deterministic ciphertext is equality-searchable (`eq`/`not_eq`/`in` — ash_age
encodes filter values to the same encoded form it stores); range filters and
sort on binary attributes are rejected rather than silently wrong. Erasure is
`DETACH DELETE`; crypto-shred means destroying the app-side key. See
`usage-rules.md` "Sensitive Data" for the full guidance (AshPaperTrail, maps,
migration notes).

### Telemetry

Every data-layer operation emits a `:telemetry.span`:

```
[:ash_age, :read | :create | :bulk_create | :update | :destroy | :create_edge | :destroy_edge | :traverse | :cypher, :start | :stop | :exception]
```

```elixir
:telemetry.attach(
  "ash-age",
  [:ash_age, :create, :stop],
  fn _event, %{duration: d}, meta, _ -> IO.inspect({d, meta.result}) end,
  nil
)
```

Metadata is **value-free** — schema identifiers, counts, booleans, and DSL enums
only (`resource`, `multitenancy`, `tenant?`, `result`, `row_count`, `direction`,
…); never a PK/property value, error reason, Cypher, or the tenant-derived graph
name. See `usage-rules.md` for the full per-op metadata catalog.

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
