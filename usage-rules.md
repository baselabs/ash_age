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
- Repo must define a Postgrex types module with `AshAge.Type.Agtype.Extension` and set `types:` in config
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

# Traversal
MyResource.traverse(actor, depth: 3, direction: :outgoing)

# Neighbors
MyResource.neighbors(actor, edge_label: :RELATES_TO)

# Path finding
MyResource.find_path(actor, to_id: target_id, max_depth: 4)
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
- `AshAge.Errors.TraversalDepthExceeded` — Depth limit exceeded

## Testing Patterns

**Integration tests require running AGE:**

```elixir
use MyApp.DataCase, async: false  # AGE doesn't support async

test "creates vertex" do
  {:ok, entity} = MyEntity.create(%{label: "Test"}, actor: system_actor())
  assert entity.label == "Test"
end
```

## Depth Limits

- Real-time queries (Chat GraphLookup): max 3-4 hops
- Background jobs (community detection): max 6 hops
- Traversal actions enforce these limits via `@max_realtime_depth` and `@max_background_depth`
