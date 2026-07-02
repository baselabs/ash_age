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

**Query parameter values still reach your Ecto/Postgrex logs at `:debug`.**
Parameterization (required for injection safety) passes attribute and primary-key
values as bound `$1` JSON params — Ecto's default logger prints those params,
by design, at the `:debug` level. If primary-key or attribute values must never
reach application logs, run the AGE-backed repo at `:info` or higher in production.

## Sensitive Data

ash_age stores vertex properties as JSON inside AGE. For classified values
(PII/PHI/secrets), declare them and store ciphertext:

```elixir
age do
  graph :my_graph
  repo MyApp.Repo
  sensitive [:ssn]        # fail-closed compile check
end

attributes do
  attribute :ssn, :binary  # holds app-side-encrypted bytes
end
```

**What `sensitive` verifies (and what it cannot).** The compile-time verifier
(`ValidateSensitive`) enforces a type SHAPE: every listed attribute must be
binary-storage-typed (`Ash.Type.storage_type == :binary` — `:binary`, or
wrappers like `Ash.Type.NewType` over `:binary`) or listed in `skip` (never
written to the graph). It cannot verify that the bytes are actually encrypted —
that is your application's job (AshCloak or Cloak; ash_age round-trips the
ciphertext via the tagged `$age64$` base64 wire format). A `:binary` attribute
holding plaintext bytes passes the verifier.

**Searchable vs. maximally confidential.**

- *Deterministic encryption* (same plaintext → same ciphertext) makes a field
  equality-searchable on the graph side: `eq`, `not_eq`, and `in` filters work
  on the ciphertext (ash_age encodes your filter value to the stored wire
  form). Trade-off: equal values are visibly equal in the database —
  deterministic encryption leaks equality patterns by design.
- *Randomized encryption* (unique IV per write) maximizes confidentiality; the
  field is NOT searchable — read and decrypt app-side.
- Range filters (`>`, `<`, `>=`, `<=`) and `sort` on binary-storage attributes
  are REJECTED (`UnsupportedFilter` / unsortable at query build): the stored
  form is tagged base64, which does not preserve byte order, so a range or
  sort would return silently wrong results.

**The multitenancy discriminator stays plaintext by design.** It is a
filter/graph selector, not secret content: Ash core injects it as a plaintext
filter and force-set, and ash_age holds no key material. `sensitive` rejects
the discriminator, and the verifier rejects a binary-storage-typed discriminator
outright.

**Edges.** An edge property that names a sensitive attribute must be backed by
a binary-storage-typed DECLARED action argument — verified at compile time and
again at runtime (an injected/undeclared argument fails the edge write closed).

**Maps and lists.** JSON cannot hold raw bytes: a non-UTF-8 binary nested
inside a `:map`/`:list` value fails closed with a value-free error naming the
attribute (AshPostgres jsonb has the same property). Encode app-side
(`Base.encode64`) or use a top-level `:binary` attribute.

**Erasure and crypto-shred.** `destroy` runs `DETACH DELETE` — the vertex and
every incident edge are removed. For crypto-shred, destroy the app-side key
(per-tenant or per-record): ash_age stores only ciphertext, so key destruction
renders stored values unrecoverable. Database backups and any AshPaperTrail
versions retain ciphertext until they age out.

**AshPaperTrail.** Point version resources at a relational data layer
(AshPostgres) or add encrypted attributes to the version resource's ignore
list. A version resource on `AshAge.DataLayer` stores its `changes` map as a
vertex property, and raw ciphertext nested in that map is not JSON-encodable
(fails closed, value-free, as above).

**Ash's `sensitive?` flag.** `attribute :ssn, :binary, sensitive?: true`
controls display/log redaction in Ash core; `age do sensitive [:ssn] end`
controls storage shape in the graph. They are orthogonal — declare both for
classified fields.

**Externally-written binary rows (migration note).** ash_age reads untagged
binary-typed values verbatim (read-only grace), but all match params (filters,
primary-key match, traversal, edge endpoints) send the tagged `$age64$` form —
untagged rows are readable but not matchable/mutable through Ash. Migrate them
by rewriting the property through ash_age, or store such values as `:string`.

## Multitenancy

AshAge supports both Ash multitenancy strategies.

**`:attribute` (recommended default, high tenant cardinality).** One graph,
tenant-filtered on a discriminator attribute. Ash core does the work: reads inject
the tenant filter, writes force-change the attribute. Declare it normally:

```elixir
multitenancy do
  strategy :attribute
  attribute :org_id
end
```

- **Do NOT list the multitenancy attribute in `age do skip [...]`** — AshAge fails
  compilation if you do (skipping it means the tenant discriminator is never
  written, so the tenant filter would silently match nothing).
- **Do NOT put the multitenancy attribute in an action's `accept`** — pass the
  tenant via `tenant:`; Ash sets/scopes it. (Listing it in `accept` makes Ash's
  required-input check reject the create.)
- Index the discriminator for selective tenant reads:
  `create_vertex_index("my_graph", "MyLabel", "org_id")`.

**`:context` = graph-per-tenant (physical isolation).** Each tenant gets its own
AGE graph (the schema-per-tenant analog). Declare `strategy :context` (no
attribute):

```elixir
multitenancy do
  strategy :context
end
```

- The graph name is derived from the tenant by a collision-free encoder: an
  identifier-clean tenant (ULID, integer, slug) becomes `t_<tenant>`; anything
  else (e.g. a UUID with hyphens) is base32-encoded as `g<...>`. A tenant longer
  than the 63-byte PostgreSQL identifier limit (~38 bytes for a hyphenated/UUID
  tenant) **fails closed** — supply a `tenant_graph` MFA to map long tenants.
- Override the mapping per resource:

  ```elixir
  age do
    graph :unused_base   # required by the DSL; the tenant graph replaces it
    repo MyApp.Repo
    tenant_graph {MyApp.Tenancy, :graph_for, []}   # apply(m, f, [tenant | a]) → identifier
  end
  ```

- **Provision each tenant's graph before use** (host-owned; AshAge never creates
  graphs at request time). Use the SAME graph name AshAge resolves at query time:

  ```elixir
  graph = AshAge.tenant_graph(MyApp.Doc, tenant)
  AshAge.Migration.provision_tenant(MyApp.Repo, graph, vlabels: ["Doc"], elabels: ["LINKS"])
  ```

  `provision_tenant/3` is idempotent and works at runtime (tenant onboarding) or
  inside a migration. A query against an unprovisioned tenant graph **fails closed**
  with a redacted database error — never silent empty results.
- A `:context` write with a nil/blank tenant fails closed (there is no global
  graph). Cross-graph writes in a single transaction (two differently-tenanted
  `:context` resources) are undefined — out of scope.

**Mutation scoping.** For `:attribute` (and any `Ash.Policy` filter), the tenant/
policy filter is applied to `update`/`destroy` WHERE clauses, not just reads —
a changeset carrying another tenant's primary key cannot modify or delete that
tenant's rows. A scoping-denied `destroy` returns `Ash.Error.Query.NotFound`
(a no-match / already-deleted destroy therefore returns `NotFound`, not `:ok`).

**Choosing a strategy.** `:attribute` scales to many tenants in one graph (index
the discriminator) and is the default recommendation. `:context` gives physical
isolation at the cost of one PostgreSQL schema per tenant (catalog/planning cost
grows with tenant count) — prefer it for strong-isolation, moderate-cardinality
tenancy.

## Multitenancy — DB-enforced RLS

Opt-in, `:attribute`-only defense-in-depth: PostgreSQL Row-Level Security (RLS)
enforced by the database itself, beneath Ash's app-layer tenant filter. Declare a
custom GUC (a PostgreSQL runtime configuration parameter) name in the `age` block:

```elixir
multitenancy do
  strategy :attribute
  attribute :org_id
end

age do
  graph :my_graph
  repo MyApp.Repo
  rls_guc "ash_age.tenant_id"   # opt-in; requires :attribute, incompatible with global? true
end
```

- **Enable it in a migration** with `AshAge.Migration.enable_tenant_rls/2` (derives
  graph/label/tenant-property/GUC from the resource DSL, so the DB policy can never
  drift from what the data layer sets at runtime):

  ```elixir
  def up do
    AshAge.Migration.enable_tenant_rls(MyApp.Repo, MyApp.Doc)
  end
  ```

  This emits `ENABLE`/`FORCE ROW LEVEL SECURITY`, a functional btree index on the
  tenant discriminator, and an expression-based policy over `properties` — **never**
  a `GENERATED ALWAYS ... STORED` column. A stored generated column on an AGE label
  table segfaults every `cypher()` write (crash + recovery) on this AGE build; the
  policy predicate is a live expression instead.
- **The DB role MUST be a non-superuser without `BYPASSRLS`.** RLS (including
  `FORCE ROW LEVEL SECURITY`) is silently skipped for superusers and roles with
  `BYPASSRLS` — deploy the application's connection role without that attribute, or
  the policy never applies and you get no error, just no enforcement.
- **Read-confidentiality backstop, not the write barrier.** `ag_catalog.cypher()`
  `CREATE` **bypasses `WITH CHECK`** on this AGE build — a cross-tenant INSERT is
  **not** RLS-denied at the database. The real write barrier is the `:attribute`
  app-layer force-set Ash core already performs (the changeset's tenant attribute is
  force-set, not attacker-controlled). RLS's distinct value is DB-enforced
  read-confidentiality: a connection whose GUC is unset/blank or set to a different
  tenant sees zero rows on `SELECT`, and update/destroy WHERE-targeting is likewise
  DB-scoped. For `:attribute` resources this read-scoping is redundant to (jointly
  enforced with) Ash's own tenant WHERE filter — RLS is the backstop beneath it, not
  a replacement.
- **Fail-closed on a blank/unset GUC.** The policy predicate requires
  `current_setting(guc, true) <> ''`; an unset or empty GUC matches zero rows rather
  than falling through to unscoped access.
- `AshAge.with_tenant_rls/4` is the auditable way to tenant-scope raw `AshAge.cypher/5`
  calls: it runs `fun` inside a transaction with the GUC `set_config`'d on the same
  pinned connection. Do not hand-roll `set_config` around a raw cypher call — use this.
- Incompatible with `global? true` (a global/tenantless read sets no GUC, so RLS
  would hide all rows) and with `:context` multitenancy (already physical
  isolation via graph-per-tenant) — both are compile-time verifier errors.
- `mix ash_age.verify --resource MyApp.Doc` detects drift between the DSL's
  `rls_guc` and the DB's actual policy (missing RLS, or a policy that doesn't
  reference both the tenant property and the GUC), and exits non-zero on failure —
  wire it into CI/precommit alongside the extension/search_path checks.

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

**Binary attributes use a self-identifying wire format.** Values for
`:binary`/`Ash.Type.Binary` attributes are stored as `"$age64$" <> base64(value)`.
The `$age64$` tag makes read-back deterministic: a stored string is base64-decoded
**only** when it carries the tag, so a value ash_age did not encode — legacy data
written by a version predating this format, or a property populated out-of-band —
is returned verbatim and never guess-decoded, even if it happens to be syntactically
valid base64. AshCloak-encrypted fields round-trip transparently. (`$` is outside
the base64 alphabet, so the tag cannot collide with the encoded body; values reach
Cypher only as the `$1` JSON parameter, so the tag never touches query syntax.)

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

## Edges

Edges connect vertices within a graph via the `edge` DSL configuration:

```elixir
age do
  graph :my_graph
  repo MyApp.Repo
  
  edge :author do
    label :AUTHORED
    direction :outgoing
    destination MyApp.Author
    properties [:weight]
  end
end
```

**Creating edges:** Use the `AshAge.Changes.CreateEdge` change on an action:

```elixir
actions do
  create :create_with_author do
    argument :author_id, :uuid
    change {AshAge.Changes.CreateEdge, edge: :author, to: :author_id}
  end
end
```

`to:` names an action argument holding the destination primary key (or a list of keys for multiple edges). `to:` is optional — a nil/empty value writes no edge. Edge property values come from **same-named action arguments**; each property MUST have a declared argument whose type governs serialization (binary → `$age64$`-tagged base64, DateTime/Date → ISO8601). Unset (nil) property arguments are omitted — sparse storage, matching single-create vertex semantics.

**Destroying edges:** Use `AshAge.Changes.DestroyEdge` symmetrically:

```elixir
actions do
  destroy :remove_author do
    argument :author_id, :uuid
    change {AshAge.Changes.DestroyEdge, edge: :author, to: :author_id}
  end
end
```

A 0-row destroy (edge already gone or out of scope) returns `Ash.Error.Changes.StaleRecord`.

**Direction:**
- `:outgoing` — stored as `(source)-[edge]->(destination)`
- `:incoming` — stored as `(destination)-[edge]->(source)`
- `:both` — stored as `:outgoing` but readable via undirected Cypher match (e.g., `MATCH (a)-[e]-(b)`) from either end

**Constraints:**
- Destination resources **must have a single-attribute primary key** (composite-PK destinations are not supported).
- Edges are isolated by tenant: `:context` graphs are graph-per-tenant (a cross-tenant destination isn't found); `:attribute` edges scope both endpoints by the tenant discriminator (a cross-tenant link fails closed with `InvalidRelationship`).

**Atomicity:** Edge creation/destruction runs inside the action's transaction via `after_action`; an edge write failure rolls the vertex back.

## Traversal

Bounded variable-length graph traversal is exposed as an Ash **manual relationship**
via `AshAge.ManualRelationships.Traverse`:

```elixir
has_many :descendants, MyApp.Node do
  manual {AshAge.ManualRelationships.Traverse,
          edge_label: :LINK,
          direction: :outgoing,   # :outgoing | :incoming | :both
          min_depth: 1,           # optional, defaults to 1
          max_depth: 3}           # REQUIRED, integer >= 1
end
```

**Options:**
- `edge_label` (required) — the edge label to traverse (identifier-validated).
- `direction` — `:outgoing` (default), `:incoming`, or `:both` (undirected match).
- `min_depth` — integer `>= 1`, `<= max_depth` (defaults to `1`).
- `max_depth` (required) — integer `>= 1`. **Unbounded `*` is forbidden** — every
  traversal is depth-bounded.

**Result shape:** load produces a source-PK-keyed map of materialized destination
records. Destinations are **deduped per source** (in Elixir, by destination primary
key — no SQL `DISTINCT`) and **cardinality-aware**: a `has_one` manual relationship
yields a single record per source, `has_many` yields a list. Works with both
**single and composite primary keys** on source and destination.

**Tenancy is FAIL-CLOSED:**
- `:context` — resolves the per-tenant graph; a nil/blank tenant fails closed.
- `:attribute` — scopes **every node on the path** to `$tenant`. Scoping fires when
  **either** the source **or** the destination resource is `:attribute`-multitenant
  (a source-`:attribute` traversal to a non-tenant destination is scoped, never run
  unscoped). Because this AGE build's Cypher parser rejects the
  `ALL(n IN nodes(p) WHERE …)` per-hop predicate, attribute scoping is implemented
  as a **fixed-length UNION expansion**: one basic `MATCH` branch per length in
  `min_depth..max_depth`, each binding every node (`a`, intermediates, `b`) and
  AND-ing `<node>.<attr> = $tenant`, joined with `UNION ALL`. A nil/blank tenant
  fails closed. **Cost note:** the expansion runs one branch per length in
  `min_depth..max_depth` (each re-`UNWIND`ing `$ids`), so a wide `:attribute` depth
  span multiplies the per-query work by the branch count — keep the span tight.

Values reach Cypher only as `$` parameters; every identifier is validated.

The `:traverse` telemetry span carries `destination_count` (post-dedup),
`row_count` (pre-dedup fan-out — genuinely larger than `destination_count` when
multiple paths reach the same destination), `depth` (`max_depth`), and `result`.

## Raw Cypher

For graph queries Ash's DSL cannot express, `AshAge.cypher/5` is a parameterized
escape hatch:

```elixir
AshAge.cypher(MyApp.Repo, "my_graph",
  "MATCH (n:Person)-[:KNOWS*1..2]->(m) WHERE n.id = $id RETURN m",
  %{"id" => person_id},
  [{:m, :agtype}])
#=> {:ok, [%{m: %AshAge.Type.Vertex{...}}, ...]}
```

**Signature:** `AshAge.cypher(repo, graph, cypher, params \\ %{}, return_types)`.

**Contract:**
- **Values reach AGE only as `$` parameters** (`params`) — the `cypher` body is
  yours to write. The `graph` name is `validate_identifier!`-checked, and a `$$`
  break-out in the body is rejected.
- **Return:** `{:ok, [row_map]}` (each `row_map` is `%{column_atom => decoded}`,
  keyed by the atoms in `return_types`) or `{:error, %AshAge.Errors.QueryFailed{}}`.
  Each cell decodes to a `%AshAge.Type.Vertex{}` / `Edge{}` / `Path{}` or a scalar.
- **Aggregate boundary:** a bare agtype **aggregate** (`collect(n)`, a map literal
  `{k: v}`) is returned as its **raw agtype string** — aggregate decoding is out of
  scope. Use Cypher `UNWIND` to project collections into individual rows.
- **Tenancy is explicit:** the `graph` you pass IS the isolation boundary. `cypher/5`
  opens no transaction of its own; for RLS defense-in-depth, call it inside your own
  tenant-GUC (`SET LOCAL`) transaction.

## Bulk Create

`can?(:bulk_create)` is now `true`. `Ash.bulk_create` emits a single `UNWIND $rows AS row CREATE (n:Label) SET n.key = row.key … RETURN n` per key-set group.

**Key-set grouping:** Rows are grouped by their attribute key-set — a row with an optional attribute missing is NOT null-filled to match other rows. Each group's `UNWIND` emits SET clauses for exactly that group's keys, preserving single-create's sparse stored shape.

**Ordering:** With `return_records?: true`, records are returned in the order they were input, paired back to their changesets via `bulk_create_index`.

**Binary/date values:** Round-trip correctly through the `$rows` parameter nesting (same `$age64$`/ISO8601 serialization as single-create).

**Atomicity:** `UNWIND` is one statement — atomic per batch (`{:error, …}` on any failure), not `:partial_success`. On the default `transaction: :batch` path (Ash wraps the batch in a transaction), a later-group failure rolls back earlier groups; under `transaction: false` a partial write is possible (same contract single-create and AshPostgres carry). A `:context` bulk with a nil tenant fails closed.

## Telemetry

Every data-layer operation emits a `:telemetry.span`:

```
[:ash_age, :read | :create | :bulk_create | :update | :destroy | :create_edge | :destroy_edge | :traverse | :cypher, :start | :stop | :exception]
```

Attach a handler the usual way:

```elixir
:telemetry.attach_many(
  "ash-age-metrics",
  [
    [:ash_age, :create, :stop],
    [:ash_age, :bulk_create, :stop],
    [:ash_age, :read, :stop]
  ],
  fn _event, measurements, metadata, _config ->
    # measurements: %{duration: native_time, monotonic_time: ...}
    # metadata: value-free — see below
  end,
  nil
)
```

**Metadata is value-free.** It carries schema identifiers, counts, booleans, and DSL enums only — **never** a primary-key or property value, an error reason, a Cypher/filter string, or the tenant-derived `graph` name:

| Key | Ops | Meaning |
|---|---|---|
| `resource` | all (`:start`) | the Ash resource module |
| `multitenancy` | all (`:start`) | `nil \| :attribute \| :context` (the strategy, not the tenant) |
| `result` | all (`:stop`) | `:ok \| :error` |
| `row_count` | read | rows returned |
| `tenant?` | writes | whether the op was tenant-scoped (boolean) |
| `stale?` | update/destroy | the 0-row not-found path (boolean) |
| `batch_size`, `group_count` | bulk_create | rows in the batch / key-set groups |
| `destination_count`, `direction`, `properties?` | create_edge/destroy_edge | edges written / edge direction / any properties set (`properties?` create only) |
| `destination_count`, `row_count`, `depth`, `direction` | traverse | destinations (post-dedup) / rows (pre-dedup fan-out) / `max_depth` / traversal direction |
| `row_count` | cypher | rows returned |

`:exception` fires only on a programmer/config error (e.g. an undeclared `edge:`) — DB errors are returned as redacted `{:error, _}` tuples and surface as `:stop` with `result: :error`. Its `kind`/`reason`/`stacktrace` are Erlang-standard telemetry-span data and are intentionally **outside** the value-free contract.

## Supported Capabilities

- CRUD: `:read`, `:create`, `:update`, `:destroy`
- Multitenancy: `:attribute` (single graph, tenant-filtered) and `:context` (graph-per-tenant); `changeset.filter` scoping honored on update/destroy
- Primary keys: single-attribute (`:id` or any attribute name) and composite
- Binary attributes: `:binary` / `Ash.Type.Binary` (and AshCloak-encrypted fields) round-trip via base64
- Transactions: `:transact` with `rollback/2`
- Filtering: `:eq`, `:not_eq`, `:gt`, `:lt`, `:gte`, `:lte`, `:in`, `:is_nil`
- Boolean expressions: `and`, `or`, `not`
- Sort, limit, offset
- Bulk create: `UNWIND` grouping, order-preserving, atomic-per-batch
- Edges: create/destroy via `AshAge.Changes.{CreateEdge, DestroyEdge}`, properties, `:both` direction
- Traversal: bounded variable-length via `AshAge.ManualRelationships.Traverse` (all directions incl. `:both`, per-source dedup, cardinality-aware, fail-closed tenancy)
- Raw Cypher: `AshAge.cypher/5` parameterized escape hatch (decoded rows, explicit-graph tenancy)
- Telemetry: value-free `[:ash_age, <op>, :start | :stop | :exception]` spans on every operation
