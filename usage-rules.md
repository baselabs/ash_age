# ash_age usage rules

_An Ash DataLayer for Apache AGE graph database._

## DataLayer Configuration

**Pattern:** Configure Ash resources to use AshAge.DataLayer with an `age do` block.

```elixir
use Ash.Resource,
  domain: MyApp.Domain,
  data_layer: AshAge.DataLayer

age do
  graph :my_graph           # Required: AGE graph name
  repo MyApp.Repo           # Required: Ecto.Repo with AGE extension
  label :MyLabel            # Optional: vertex label (defaults to resource short name)
  skip [:computed]          # Optional: properties to exclude from AGE
end
```

**Important:**
- Repo must define a Postgrex types module with `AshAge.Postgrex.AgtypeExtension` and set `types:` in config
- Graph must exist in PostgreSQL (create via migration or `mix ash_age.gen.migration`)
- Repo must have `after_connect: {AshAge.Session, :setup, []}` in config
- Search path must include `ag_catalog` and `public` (Session.setup handles this)
- Session.setup sets search_path to: `public, ag_catalog, "$user"` — this order prevents `ag_catalog.schema_migrations` from shadowing Ecto's `public.schema_migrations`
- Run `mix ash_age.install` for full setup instructions
- Run `mix ash_age.verify` to check your database configuration

## Query Operations

**Read operations** work through Ash.Query:

```elixir
# Simple filters
MyResource
|> Ash.Query.filter(label == "Entity")
|> Ash.Query.for_read(:read)
|> Ash.read!()
```

**Restrictions:**
- NO JOIN operations (use Cypher traversal instead)
- NO aggregate subqueries in filters
- NO bulk_create (sequential creates only)
- NO upsert (use MATCH + conditional CREATE)
- NO lateral_join operations
- NO like/ilike filters (use regex or application-side filtering)

## Security Requirements

**ALL dynamic values MUST use parameterized queries:**

- NEVER interpolate values into Cypher strings
- AshAge.Query.Filter.translate/2 automatically handles parameterization
- Raw Cypher via Ecto.Adapters.SQL.query must use parameterized format:
  ```elixir
  AshAge.Cypher.Parameterized.build(graph, cypher, %{"param" => value})
  ```

**Error messages are redacted:** AshAge never puts filtered values or PostgreSQL
`DETAIL` lines (which echo row values) into error messages or logs.
`AshAge.Errors.UnsupportedFilter` reports the operator and field only;
create/update/query failures report the SQLSTATE code (and constraint name) only.

## AGE Limitations

**NOT supported (returns {:error, UnsupportedFilter}):**
- like/ilike filters (use regex or application-side filtering)
- Aggregate subqueries
- Exists subqueries
- shortestPath() function (performance issues — can take minutes on moderate graphs)
- all()/any()/none()/single() predicates
- IN clauses with subqueries

**SEVERELY BUGGY (NEVER USE):**
- MERGE command (exponential performance, duplicates, missing ON CREATE/MATCH SET)
  - Use CREATE + SET pattern instead
  - For idempotency: MATCH first, then CREATE if not found

**Known Issues:**
- AGE 1.1.0 has several Cypher implementation bugs
- collect() IS supported (despite some docs claiming otherwise)
- OPTIONAL MATCH works for simple patterns but bugs with multi-pattern
- datetime() function not supported (use application-side timestamp conversion)

## Migration Patterns

**Create graph, labels, and indexes:**

```elixir
defmodule MyApp.Repo.Migrations.CreateAgeGraph do
  use Ecto.Migration
  import AshAge.Migration

  def up do
    create_age_graph("my_graph")
    create_vertex_label("my_graph", "Entity")
    create_vertex_index("my_graph", "Entity", "tenant_id")
  end

  def down do
    drop_age_graph("my_graph")
  end
end
```

**Important:** Index SQL must use fully-qualified `ag_catalog.agtype_access_operator()` function instead of `->>` operator, because `public` comes before `ag_catalog` in search_path.

## Error Handling

**Common errors:**

- `AshAge.Errors.QueryFailed` — AGE query execution failed
- `AshAge.Errors.CreateFailed` — Vertex creation failed
- `AshAge.Errors.UpdateFailed` — Vertex update failed
- `AshAge.Errors.UnsupportedFilter` — Filter not supported by AshAge

## Testing Patterns

**Integration tests require running AGE:**

```elixir
use MyApp.DataCase, async: false  # AGE doesn't support async

test "creates vertex" do
  {:ok, entity} = MyEntity.create(%{label: "Test"}, actor: system_actor())
  assert entity.label == "Test"
end
```

### Testing against a live AGE database

AGE tests hit a real database and cannot run against an in-memory adapter. Gate them
so the rest of your suite still runs with no database:

- Point tests at a live AGE via an env var (e.g. `AGE_DATABASE_URL`), and start your
  test `Ecto.Repo` with `pool: Ecto.Adapters.SQL.Sandbox` + `after_connect: {AshAge.Session, :setup, []}`
  only when it is set; otherwise `ExUnit.start(exclude: [:integration])`.
- Tag AGE tests `@moduletag :integration` and run them with `async: false` (AGE does not
  support concurrent transactions).
- Graph/label creation is DDL and is **not** rolled back by the Sandbox transaction —
  create each test's graph (unique name) on an unboxed connection and `drop_graph/2` it
  afterward for isolation, rather than relying on transactional rollback.
- Run locally against a throwaway AGE container mapped to a free host port, e.g.
  `AGE_DATABASE_URL=postgres://postgres:postgres@localhost:5462/ash_age_test mix test`.

## Supported Capabilities

- CRUD: `:read`, `:create`, `:update`, `:destroy`
- Primary keys: single-attribute (`:id` or any attribute name) and composite
- Binary attributes: `:binary` / `Ash.Type.Binary` (and AshCloak-encrypted fields) round-trip via base64
- Transactions: `:transact` with `rollback/2`
- Filtering: `:eq`, `:not_eq`, `:gt`, `:lt`, `:gte`, `:lte`, `:in`, `:is_nil`
- Boolean expressions: `and`, `or`, `not`
- Sort, limit, offset
