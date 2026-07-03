# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Getting-started [Livebook](https://livebook.dev) guide (`notebooks/getting_started.livemd`),
  rendered in the docs and executed against Apache AGE in CI.

## [1.0.0] - 2026-07-03

The first stable release. A large, mostly **additive** expansion over `0.2.x`:
multitenancy (`:attribute` and `:context`),
graph edges, bounded traversal, DB-enforced RLS, sensitive-data classification,
raw Cypher, bulk create, and composite primary keys. Existing `0.2.x` builds are
unaffected until you upgrade.

### Upgrading from 0.2.x

A few behavior changes to check before upgrading (the rest is new capability):

- **`update`/`destroy` on a missing or filter-excluded row now return
  `Ash.Error.Changes.StaleRecord`** (previously `Ash.Error.Query.NotFound`;
  `destroy` previously returned `:ok` on a no-match). Update any code that
  pattern-matches on the old error.
- **`update`/`destroy` now honor `changeset.filter`** — mutations are scoped by
  the tenant/policy filter Ash attaches, not matched by primary key alone. This
  closes a cross-tenant write/delete gap; behavior changes only if you relied on
  the previous unscoped matching.
- **`AshAge.DataLayer.Info.attribute_types/1` now returns `{type, constraints}`
  tuples** (was bare types). Only affects code calling that introspection helper
  directly.
- **New compile-time checks** reject a primary key listed in `age skip` and a
  binary-typed multitenancy discriminator — both were already silently broken
  (perpetual `StaleRecord` / inconsistent scoping).

Binary attribute storage (`$age64$`), range/sort rejection on binary storage,
and sensitive classification are new and do not affect existing non-binary
resources.

### Added

- **Sensitive classification (S7).** `age do sensitive [:attrs] end` +
  `AshAge.DataLayer.Info.sensitive/1`: fail-closed compile-time verifier
  (`ValidateSensitive`) — each sensitive attribute must be binary-storage-typed
  (app-side-encrypted bytes) or skipped; the multitenancy discriminator cannot be
  sensitive; sensitive-named edge properties require binary-storage-typed declared
  arguments (verified again at runtime on the edge write path). Spark surfaces
  verifier errors as compiler diagnostics; build with `--warnings-as-errors`
  to make them blocking.
- `ValidateSkip` verifier: a primary-key attribute in `age skip` is now a verifier
  error (previously: every update/destroy silently returned StaleRecord).
- usage-rules/README "Sensitive Data" guidance: searchable-vs-encrypted,
  erasure/crypto-shred, AshPaperTrail, plaintext-discriminator rationale.
- **DB-enforced RLS (S6).** Opt-in `:attribute`-only PostgreSQL Row-Level Security,
  a defense-in-depth read-confidentiality backstop beneath Ash's app-layer tenant
  filter:
  ```elixir
  age do
    graph :my_graph
    repo MyApp.Repo
    rls_guc "ash_age.tenant_id"
  end
  ```
  - `AshAge.DataLayer.Info.rls_guc/1` reads the DSL option; a compile-time verifier
    (`AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr`) requires `:attribute`
    multitenancy and rejects `global? true` (a global read sets no GUC, so RLS would
    hide every row).
  - `AshAge.Migration.enable_tenant_rls/2` (resource-derived) and `/5` (explicit
    graph/label/tenant-property/GUC) emit `ENABLE`/`FORCE ROW LEVEL SECURITY`, a
    functional btree index on the tenant discriminator, and a fail-closed expression
    policy over `properties` (`current_setting(guc, true) <> '' AND <discriminator> =
    current_setting(guc, true)`) — **never** a `GENERATED ALWAYS ... STORED` column.
  - All five CRUD callbacks (`read`, `create`, `update`, `destroy`, `bulk_create`)
    and traversal (`AshAge.ManualRelationships.Traverse`) route through a new
    `with_rls/4` wrapper: off (no `rls_guc`) is a no-op; on, it `set_config`s the GUC
    inside `repo.transaction` (pinning one connection) before running the operation,
    and fails closed with `:rls_tenant_required` on a blank/nil tenant before any
    query runs. `unwrap_rls/2` normalizes the result back to the data-layer contract.
    A new `rls?` key joins the value-free telemetry metadata allowlist.
  - `AshAge.with_tenant_rls/4` — the auditable way to tenant-scope raw
    `AshAge.cypher/5` calls: runs `fun` inside a transaction with the GUC
    `set_config`'d on the same pinned connection.
  - `mix ash_age.verify --resource MyApp.Doc` detects RLS drift (RLS not enabled,
    or a policy that doesn't reference both the tenant property and the GUC) and now
    **exits non-zero** on any failing check (previously always exited 0).
  - **Three load-bearing AGE constraints this design is built around** (each
    verified live against `apache/age:release_PG16_1.6.0`):
    1. A `GENERATED ALWAYS ... STORED` column on an AGE label table **segfaults
       every `cypher()` write** (signal 11, crash + recovery) — the RLS predicate
       must be a live expression over `properties`, never a generated column.
    2. AGE `cypher()` **CREATE bypasses `WITH CHECK`** — a cross-tenant INSERT is
       **not** RLS-denied at the database. RLS is read/target-side only; the
       `:attribute` app-layer force-set (Ash core) remains the actual write
       barrier.
    3. RLS (including `FORCE ROW LEVEL SECURITY`) is **silently skipped for
       superusers and roles with `BYPASSRLS`** — the application's DB role must be
       a non-superuser without `BYPASSRLS`, or the policy never applies with no
       error signal.
  - For `:attribute` resources, RLS's row-scoping is redundant to (jointly enforced
    with) Ash's own tenant WHERE filter — RLS's distinct value is the DB-enforced
    read-confidentiality backstop beneath the app layer, not a replacement for it.
- **Traversal (S5).** `AshAge.ManualRelationships.Traverse` — bounded variable-length
  graph traversal exposed as an Ash manual relationship:
  ```elixir
  has_many :descendants, MyApp.Node do
    manual {AshAge.ManualRelationships.Traverse,
            edge_label: :LINK, direction: :outgoing, min_depth: 1, max_depth: 3}
  end
  ```
  - Returns a source-primary-key-keyed map of materialized destination records,
    **deduped per source** (in Elixir, by destination PK — no SQL `DISTINCT`, so
    `row_count` telemetry stays a genuine pre-dedup fan-out signal) and
    **cardinality-aware** (`has_one` → one record, `has_many` → list).
  - All three directions — `:outgoing`, `:incoming`, and undirected `:both`.
  - `max_depth` is **required** and bounded (integer `>= 1`); an unbounded `*` is
    forbidden. `min_depth` defaults to `1`. Both single and composite primary keys
    on source and destination are supported.
  - **Fail-closed tenancy.** `:context` resolves the per-tenant graph (nil/blank
    tenant fails closed); `:attribute` scopes **every node on the path** to
    `$tenant` via a **fixed-length UNION expansion** — one basic `MATCH` branch per
    length in `min_depth..max_depth`, each node AND-scoped to the discriminator,
    `UNION ALL`-joined. (This AGE build's Cypher parser rejects the
    `ALL(n IN nodes(p) WHERE …)` per-hop predicate, so the UNION expansion is the
    shipped mechanism — see probes below.)
  - Emits a value-free `:traverse` telemetry span with `destination_count`
    (post-dedup), `row_count` (pre-dedup fan-out), `depth` (`max_depth`),
    `direction`, and `result`.
- **Raw Cypher (S5).** `AshAge.cypher(repo, graph, cypher, params \\ %{}, return_types)`
  — a parameterized escape hatch for queries the Ash DSL cannot express:
  ```elixir
  AshAge.cypher(MyApp.Repo, "my_graph",
    "MATCH (n:Person)-[:KNOWS*1..2]->(m) WHERE n.id = $id RETURN m",
    %{"id" => person_id}, [{:m, :agtype}])
  #=> {:ok, [%{m: %AshAge.Type.Vertex{...}}, ...]}
  ```
  - Values reach AGE **only as `$` parameters**; the `graph` name is
    `validate_identifier!`-checked and a `$$` break-out in the body is rejected.
  - Returns `{:ok, [%{column_atom => decoded}]}` (each cell a
    `%AshAge.Type.Vertex{}` / `Edge{}` / `Path{}` or a scalar) or
    `{:error, %AshAge.Errors.QueryFailed{}}`.
  - **Decode boundary:** a bare agtype aggregate (`collect(n)`, `{k: v}`) is returned
    as its **raw agtype string** — aggregate decoding is out of scope; use `UNWIND`.
  - **Tenancy is explicit:** the `graph` you pass IS the isolation boundary;
    `cypher/5` opens no transaction of its own (wrap in your own tenant-GUC
    transaction for RLS defense-in-depth).
  - Emits a value-free `:cypher` telemetry span with `row_count` and `result`; `:depth`
    was added to the telemetry value-free metadata allowlist this slice.
- Feasibility probes verifying AGE 1.6.0 behavior this slice depends on:
  `UNWIND` + variable-length `MATCH` (P-S5a = supported); a bound path variable with
  `ALL(n IN nodes(p) WHERE …)` (P-S5b = **rejected** by this AGE build); the
  fixed-length `UNION ALL` expansion as its equivalent (P-S5b-UNION = supported);
  and `IN $param` list binds (P-S5c = supported).
- **Data-layer telemetry.** Every operation emits a `:telemetry.span` — `[:ash_age, :read | :create | :bulk_create | :update | :destroy | :create_edge | :destroy_edge, :start | :stop | :exception]`:
  - Metadata is **value-free** — schema identifiers, counts, booleans, and DSL enums only (`resource`, `multitenancy`, `tenant?`, `stale?`, `properties?`, `direction`, `row_count`, `batch_size`, `group_count`, `destination_count`, `result`). Never a PK/property value, error reason, Cypher/filter string, or the tenant-derived graph name.
  - `AshAge.Telemetry` (a new dependency-free module) owns the metadata allowlist and raises on any off-allowlist key — the single enforcement point for the value-free contract.
  - `:exception` fires only on a programmer/config error (e.g. an undeclared `edge:`); DB errors are returned as redacted `{:error, _}` tuples and surface as `:stop` with `result: :error`.
  - `:telemetry` is now a declared runtime dependency (already resolved transitively via `ash`/`ecto`).
- **Edge CRUD (S4).** Two Ash `Resource.Change` modules for creating and destroying graph edges:
  - `AshAge.Changes.CreateEdge` — creates edges via `change {AshAge.Changes.CreateEdge, edge: :name, to: :arg}`, parameterized endpoint matching, optional edge properties (values from same-named action arguments, type-serialized as vertex attributes), atomic write inside the action's transaction (0-row match or DB error rolls the vertex back). Tenant-isolated: `:context` edges are same-graph fail-closed; `:attribute` edges scope both endpoints by the tenant discriminator.
  - `AshAge.Changes.DestroyEdge` — destroys edges symmetrically, returning `Ash.Error.Changes.StaleRecord` on 0-row match (already gone or out of scope).
  - Edge `properties` DSL option — a list of property keys, values sourced from same-named action arguments (declared argument type governs serialization: binary → `$age64$`-tagged base64, DateTime/Date → ISO8601). Unset properties are sparse (not written as null).
  - `:both` direction — stored as `:outgoing`, readable via undirected Cypher match from either endpoint (contract for S5 traversal, pinned by integration test).
  - Constraint: edge destinations must have a **single-attribute primary key**.
  - Edge-label auto-creation: AGE auto-creates edge labels on first `CREATE` (verified live by probe P4); no provisioning required. Edge labels are provisioned like vertex labels: via `create_edge_label/2` in migrations or `:elabels` in `provision_tenant/3`.
- **Bulk create (S4).** `can?(:bulk_create)` is now `true`. `Ash.bulk_create` emits `UNWIND $rows AS row CREATE (n:Label) SET n.key = row.key … RETURN n` per key-set group:
  - Key-set grouping — rows are grouped by which attributes are present, so a row with an optional attribute missing is NOT null-filled to match other rows. Each group's `UNWIND` emits SET clauses for exactly that group's keys, preserving single-create's sparse stored shape.
  - Order-preserving — with `return_records?: true` records come back mapped to input changesets via `bulk_create_index`; positional order matches input.
  - Binary/date round-trip — values serialize identically to single-create (`$age64$`/ISO8601) and survive nested in the `$rows` parameter.
  - Atomic-per-batch — one `UNWIND` statement, so any row's DB error fails the whole batch (`{:error, …}`, not `:partial_success`). On `transaction: :batch` (default, Ash wraps the batch), a later-group failure rolls back earlier groups; on `transaction: false` partial writes are possible (same contract single-create and AshPostgres carry). `:context` batches with a nil tenant fail closed.
- **Multitenancy (S3).** Both Ash multitenancy strategies are now supported
  (`can?(:multitenancy) → true`):
  - **`:attribute`** — works through Ash core (reads inject a tenant filter,
    writes force-change the tenant). ash_age adds a fail-closed compile
    **verifier** (`AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr`): the
    multitenancy attribute must not appear in `age do skip [...]`, or the tenant
    discriminator would never be written and the core-injected filter would
    silently match nothing.
  - **`:context` — graph-per-tenant** physical isolation. `set_tenant/3` resolves
    a per-tenant AGE graph and threads it through reads; writes resolve it from
    the changeset tenant and **fail closed** on a missing tenant (there is no
    global graph). The graph name comes from a collision-free encoder
    (`AshAge.Multitenancy.graph_name/2`): identifier-clean tenants (ULID,
    integer, slug) pass through as `t_<tenant>`; others (e.g. a UUID) are
    base32-encoded as `g<...>`. The two prefixes are disjoint, so distinct
    tenants never collide. Overridable per resource via a `tenant_graph` MFA in
    the `age` DSL block. Tenants longer than the 63-byte identifier limit fail
    closed with a value-free error (use `tenant_graph`).
  - `AshAge.tenant_graph/2` — public helper so a host derives the same graph name
    query time uses.
  - `AshAge.Migration.provision_tenant/3` — idempotent, runtime-safe (and
    migration-safe) helper the host app calls to create a tenant's graph +
    labels. Every graph/label is validated as an AGE identifier before use.
  - A missing tenant graph fails **closed**: a query against an unprovisioned
    `:context` graph surfaces a redacted database error, never silent empty
    results.
- Live-AGE integration-test harness: a test `Ecto.Repo`, a Postgrex agtype types
  module, `AshAge.TestDomain`, and `AshAge.DataCase` (Ecto SQL Sandbox + AGE
  session with a `with_graph/3` helper). Integration tests are tagged
  `:integration` and run only when `AGE_DATABASE_URL` is set; the pure-unit suite
  still runs with no database.
- Feasibility probes verifying AGE 1.6.0 behavior later work depends on: bulk
  `UNWIND … SET n.k = row.k` (supported), parameterized `MATCH (a),(b) … CREATE
  (a)-[:REL]->(b)` (supported), and that `ag_catalog.cypher()` honors `FORCE`
  row-level security under a non-superuser role with a GUC-keyed policy
  (supported — confirms DB-enforced tenant isolation on AGE is viable).
- CI pins the Apache AGE service image by digest (`release_PG16_1.6.0`, AGE 1.6.0
  / PostgreSQL 16) and runs the integration lane against it.
- Unit test coverage for the previously untested query-building path:
  `AshAge.Cypher.Parameterized`, `AshAge.Query`, `AshAge.Query.Filter`,
  `AshAge.Type.Agtype`, `AshAge.Type.Cast`, and `AshAge.DataLayer.set_clauses/1`
  (47 new tests, no database required).
- `AshAge.DataLayer` declares `can?(_, :composite_primary_key) == true`, so
  resources with a composite primary key now compile and CRUD correctly.

### Fixed

- **Sensitive data / binary-storage fixes (S7).** Filter `eq`/`not_eq`/`in`,
  primary-key match (update/destroy), traversal ids, and edge endpoint params now
  encode binary-storage values to the stored `$age64$` wire form — equality search
  on encrypted (binary) attributes and binary primary keys previously never matched
  (or raised `Jason.EncodeError`).
- Non-JSON-encodable values (raw bytes nested in `:map`/`:list`, or a struct with no
  `Jason.Encoder` impl nested in a param) now fail closed with a value-free error
  naming the attribute; previously `Jason.EncodeError`/`Protocol.UndefinedError`
  leaked the raw bytes or inspected value into the exception message.
- `StaleRecord` errors no longer carry primary-key/endpoint values in their `filter`
  (Ash inspects it into log messages); the filter keeps field names and replaces each
  value with `"<redacted>"`.
- An update whose primary-key `WHERE` matches more than one row (duplicate-keyed
  vertices are creatable outside Ash — AGE enforces no PK uniqueness) now fails closed
  with a value-free `UpdateFailed` instead of raising `FunctionClauseError` across the
  data-layer callback boundary.
- Attribute-to-attribute filter comparisons (`attr1 == attr2`, and a `Ref` nested in an
  `in` list) now return `UnsupportedFilter` instead of binding the `Ref` struct as a
  parameter and surfacing downstream as a misleading "not JSON-encodable" error.
- `Ash.Type.NewType` wrappers over date/datetime types now coerce stored ISO8601
  values back to `%Date{}`/`%DateTime{}`/`%NaiveDateTime{}` on read (previously the
  raw string was returned, silently breaking traversal key-matching for wrapped date
  primary keys). Coercion dispatches on the resolved Ash STORAGE class
  (`AshAge.Type.Cast.storage_class/2`), the same resolution the binary predicate uses.
- Attribute constraints now reach every wire path (encoder, decode gate, filter cast,
  edge property guard) — a custom type whose `storage_type/1` depends on instance
  constraints can no longer pass the sensitive-classification verifier yet store
  untagged.
- **`:attribute` traversal scopes off the source strategy too (S5 closeout).**
  `AshAge.ManualRelationships.Traverse` now applies per-node tenant scoping when
  **either** the source or the destination resource is `:attribute`-multitenant.
  Previously it keyed only on the destination, so a source-`:attribute` /
  non-`:attribute`-destination traversal ran an **unscoped** query against the
  shared multi-tenant graph (fail-open); it is now fail-closed on that config too.
- **Date/DateTime source primary keys associate correctly in traversal (S5
  closeout).** The traversal F3 source key now coerces the decoded agtype scalar
  to the source attribute type (via `AshAge.Type.Cast.coerce_value/2`), so a
  `:date`/`:utc_datetime`/`:naive_datetime` primary key (stored as an ISO8601
  string, held as a struct in the record) matches Ash's manual-result lookup.
  Previously the raw string key never matched and the source was **silently
  dropped** (returned `[]`/`nil`). UUID/integer/string PKs were unaffected.
- **`In` filter handles Ash's `MapSet` right side (S5).** `AshAge.Query.Filter`
  now normalizes the `MapSet` that `Ash.Query.Operator.In` stores as its right side
  to a list before emitting `n.attr IN $param`, so `filter(x in ^list)` — and nested
  loads that flow through traversal — work. Previously the `MapSet` shape fell through
  to `{:error, UnsupportedFilter}`.
- **`AshAge.Type.Path` decodes AGE's inline-tagged path wire format (S5).** A
  `::path` body is an array of individually `::vertex`/`::edge`-tagged agtype
  elements, not plain JSON; the decoder now splits at top-level commas
  (depth- and string-literal-aware) and recursively decodes each element.
  Previously it fed the body to `Jason.decode!` and raised `Jason.DecodeError`
  (first exercised by `cypher/5` returning a path, `RETURN p`).
- `AshAge.DataLayer.update/2` no longer risks a parameter collision when a resource
  has an attribute literally named `match_id`; the internal match parameter now uses
  a name guaranteed not to clash with a changed attribute.
- Setup docs no longer show a Postgrex types snippet that fails to compile:
  `Postgrex.Types.define/3` defines the module itself, so it is now called at the
  top level (a `defmodule` wrapper of the same name raises "cannot define module …
  currently being defined"). The `mix ash_age.install` output also referenced a
  non-existent `AshAge.Type.Agtype.Extension`; the correct module is
  `AshAge.Postgrex.AgtypeExtension`. Fixed in the install task, the `AshAge`
  moduledoc, and the README.
- `AshAge.DataLayer.update/2` and `destroy/2` derive their match predicate from
  `Ash.Resource.Info.primary_key/1`, so resources with a composite primary key or
  a single non-`:id` primary key match the correct rows. Both previously hardcoded
  `WHERE n.id = $…`, silently matching the wrong rows or nothing.
- `:binary` attributes (including AshCloak-encrypted fields) no longer crash
  `Jason.encode!` on create/update. Binary values are stored in a self-identifying
  wire format (`"$age64$" <> base64(value)`) and decoded back on read; plaintext
  strings are untouched. The `$age64$` tag makes decoding deterministic — a value
  ash_age did not encode (legacy or out-of-band data) is returned verbatim, never
  guess-decoded, even if it is syntactically valid base64.

### Changed

- **Binary-storage behavior changes (S7).** Range filters (`>`, `<`, `>=`, `<=`) on
  binary-storage attributes return `UnsupportedFilter` (previously compared the
  tagged-base64 stored form — silently wrong results). Sort on binary storage is
  rejected at query build (`can?({:sort, :binary})` is false).
- Stored binary values not written by ash_age (untagged/legacy/external) are readable
  verbatim but no longer matchable through Ash filters or mutations (read-only grace):
  match params now send the tagged form. Migrate such rows or store them as `:string`.
- A binary-storage-typed multitenancy discriminator is now rejected by a verifier (it
  would scope vertex filters, edge tenant params, traversal, and RLS paths
  inconsistently).
- `AshAge.DataLayer.Info.attribute_types/1` now returns `{type, constraints}` tuples
  (previously bare types) so constraints reach the encode/decode paths;
  `AshAge.Type.Cast.serialize_value/2` and `coerce_value/2` accept both bare types
  and `{type, constraints}` specs.
- `update/2` and `destroy/2` now return `Ash.Error.Changes.StaleRecord` (was
  `Ash.Error.Query.NotFound`) when the primary-key + scoping-filter `WHERE`
  matches no row — the Ash data-layer contract for a record-based mutation whose
  row is gone or excluded by a filter (`NotFound` is for identifier lookups;
  `StaleRecord` is what the reference ETS data layer and Ash core return, and what
  Ash's bulk update/destroy paths pattern-match). `destroy/2` previously returned
  `:ok` unconditionally on a no-match (`DETACH DELETE` gives no matched/unmatched
  signal); it now detects the 0-row case (via `RETURN n`) and surfaces
  `StaleRecord`, so a scoping-denied or already-deleted destroy is observable and
  consistent with `update/2`.

### Security

- **Cross-tenant write/delete closed.** ash_age now advertises
  `can?(:changeset_filter) → true` and honors `changeset.filter` in `update`/
  `destroy`, translating it into the Cypher `WHERE` (AND-ed with the primary-key
  match). Previously the data layer matched mutations by primary key only and
  silently dropped the tenant/policy scoping filter Ash attaches, so a
  fabricated or non-tenant-scoped changeset carrying another tenant's primary
  key could modify or delete that tenant's rows. Untranslatable filters fail
  **closed** (the mutation is rejected, never silently unscoped). This also makes
  `Ash.Policy` filters apply to mutations.
- Defense-in-depth against Cypher/SQL injection at every identifier interpolation
  site. All dynamic values were already parameterized; this hardens the identifiers
  that are interpolated into the query text:
  - `AshAge.Query.to_cypher/1` now validates the vertex `label` and every `sort`
    field as an AGE identifier before interpolation, and requires `offset`/`limit`
    to be non-negative integers (raising `ArgumentError` otherwise).
  - `AshAge.DataLayer` create/update validate every property key (`SET n.key = $key`)
    and the label as AGE identifiers.
  - `AshAge.Cypher.Parameterized.build/*` now reject any Cypher body containing a
    `$$` sequence — a final centralized guard against breaking out of AGE's
    dollar-quoted literal.
  - `AshAge.Cypher.Parameterized` now validates `return_types` column names and
    types as AGE identifiers before interpolating them into the outer `AS (...)`
    record clause (which sits **outside** AGE's `$$` dollar-quote). On the public
    `AshAge.cypher/5` surface these are caller-controlled, so an unvalidated
    column name was a SQL-injection vector (S5 closeout).
  - The `$$`-body rejection no longer echoes the Cypher body in its
    `ArgumentError` message; that raise bypasses the redaction boundary, so a body
    carrying an interpolated value would otherwise leak it into logs (S5 closeout).
- Error messages no longer leak filtered values or database row contents.
  `AshAge.Errors.UnsupportedFilter` now reports only the operator and referenced
  field name (never the filtered value). `CreateFailed`/`QueryFailed`/`UpdateFailed`
  surface only the PostgreSQL SQLSTATE code (and constraint name), never the
  Postgres `DETAIL` line that echoes offending values. A regression test pins the
  never-interpolate guarantee: values reach Cypher only as the `$1` parameter.

## [0.2.6] - 2026-02-14

### Fixed

- Removed all phantom references to non-existent modules and features from documentation
- `usage-rules.md`: Corrected Postgrex extension module name (`AshAge.Type.Agtype.Extension` → `AshAge.Postgrex.AgtypeExtension`)
- `usage-rules.md`: Removed phantom `traverse()`, `neighbors()`, `find_path()` examples (not implemented)
- `usage-rules.md`: Replaced phantom depth limits section with actual supported capabilities list
- `AGENTS.md`: Removed phantom `telemetry` and `traversal` modules from dependency levels and Key Files
- `AGENTS.md`: Removed "Adding a New Traversal Pattern" section referencing non-existent files
- `AGENTS.md`: Removed phantom "Breaking depth limits" from Common Pitfalls
- Cleaned up all merged fix branches (local and remote)

## [0.2.5] - 2026-02-14

### Fixed

- README installation section showed `~> 0.1.0` instead of current version

## [0.2.4] - 2026-02-13

### Fixed

- UUID primary key overwritten by AGE internal integer ID — `maybe_put_id` used `Map.put` which unconditionally replaced the UUID extracted from vertex properties; now uses `Map.put_new` to preserve UUID when present
- Static Cypher queries passed `NULL` as third argument to `ag_catalog.cypher()` — AGE rejects this with `invalid_parameter_value`; now omits the params argument entirely for parameterless queries

## [0.2.3] - 2026-02-13

### Fixed

- `AgtypeExtension.encode/1` missing `<<byte_size(value)::int32()>>` length prefix required by Postgrex wire protocol
- `AgtypeExtension.decode/1` missing `<<len::int32(), value::binary-size(len)>>` extraction — Postgrex sends length-prefixed data on the wire

## [0.2.2] - 2026-02-13

### Fixed

- `AgtypeExtension.encode/1` returned `{:ok, value}` tuple instead of raw binary — Postgrex expects iodata, causing `ArgumentError` on all parameterized queries
- Added missing `rollback/2` callback to `AshAge.DataLayer` — Ash calls this to roll back transactions on failure but it was undefined, causing `UndefinedFunctionError`

## [0.2.1] - 2026-02-13

### Fixed

- Error struct field mismatches in `data_layer.ex` — `:message`/`:detail` fields were silently dropped at runtime because the Splode error structs only define `:reason` (and `:query` for `QueryFailed`)
- `QueryFailed` construction in `run_query/2` and `destroy/2` used non-existent `:resource` field instead of `:query`
- Removed phantom `AshAge.Errors.TraversalDepthExceeded` reference from `usage-rules.md` (module does not exist)
- Updated `AGENTS.md` version history to include v0.2.0 and v0.2.1 changes

## [0.2.0] - 2026-02-13

### Added

- `AshAge.Type.Edge` struct for AGE edge data (`id`, `label`, `start_id`, `end_id`, `properties`)
- Real agtype parser in `AshAge.Type.Agtype` — decodes `::vertex`, `::edge`, `::path` suffixes and scalar values
- Vertex-to-resource attribute mapping in `AshAge.Type.Cast` with type coercion (ISO8601 → Date/DateTime)
- DSL transformer validation: `ValidateGraph`, `EnsureLabelled`, `ValidateLabelFormat`
- Idempotent migration helpers — `create_age_graph/1`, `create_vertex_label/2`, `create_edge_label/2` now check catalog before creating

### Changed

- `AshAge.DataLayer.Info` reads all config dynamically from the resource's Spark DSL instead of hard-coded values
- `AshAge.Cypher.Parameterized` wraps Cypher in `ag_catalog.cypher()` with JSON-encoded `$1` parameter
- `AshAge.Query` generates proper `MATCH/WHERE/RETURN/ORDER BY/SKIP/LIMIT` Cypher and accumulates params in a map
- `AshAge.Query.add_param/2` correctly accumulates parameters with `$paramN` references

### Fixed

- Postgrex extension module reference: `AshAge.Type.Agtype.Extension` → `AshAge.Postgrex.AgtypeExtension` in docs and README
- Removed non-existent `AshAge.Cypher.Traversal` from doc groups in `mix.exs`

## [0.1.2] - 2026-02-13

### Added

- Add `AshAge` root module with complete setup documentation
- Add `mix ash_age.install` task for printing setup instructions
- Add `mix ash_age.gen.migration` task for generating AGE migrations
- Add `mix ash_age.verify` task for runtime AGE configuration verification
- Implement `AshAge.Session` module with `setup/1` for `after_connect` hook
- Implement `AshAge.Migration` module with graph, label, and index helpers
- Add unit tests for Session, Migration, and Mix task modules

## [0.1.1] - 2026-02-13

### Fixed

- Add missing `:filters` and `:sort` fields to `AshAge.Query` struct
- Fix pattern match arity in `AshAge.Query.to_cypher/1`
- Add module aliases to satisfy Credo strict checks
- Replace `cond` with `if/else` in `AshAge.Type.Agtype`
- Fix `mix docs` CI step to use correct MIX_ENV

## [0.1.0] - 2025-01-01

### Added

- Initial release of AshAge DataLayer for Apache AGE
- Cypher query generation from Ash queries
- Vertex and Edge resource support
- Custom Ash types: `Agtype`, `Vertex`, `Edge`, `Path`
- Graph creation and management via `AshAge.Migration`
- Session-based AGE graph binding via `AshAge.Session`
- Parameterized Cypher queries for safe value interpolation
- Query filtering with Ash filter translation

[Unreleased]: https://github.com/baselabs/ash_age/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/baselabs/ash_age/compare/v0.2.6...v1.0.0
[0.2.6]: https://github.com/baselabs/ash_age/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/baselabs/ash_age/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/baselabs/ash_age/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/baselabs/ash_age/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/baselabs/ash_age/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/baselabs/ash_age/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/baselabs/ash_age/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/baselabs/ash_age/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/baselabs/ash_age/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/baselabs/ash_age/releases/tag/v0.1.0
