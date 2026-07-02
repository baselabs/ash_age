# AshAge - AI Agent Development Guide

This file helps AI agents (Claude Code, GitHub Copilot Workspace, etc.) work effectively with ash_age codebase.

## Architecture Overview

AshAge is an Ash Framework DataLayer for Apache AGE graph database. It translates Ash queries into Cypher (AGE's query language) and manages graph vertices/edges through PostgreSQL's AGE extension.

### Module Dependency Levels

When making changes, understand these dependency levels:

**Level 0 (no deps):** `errors`, `vertex`, `edge`, `path`, `session`, `migration`, `telemetry`
**Level 1 (leaf deps):** `agtype` (→ vertex,edge,path), `parameterized` (→ errors), `agtype_extension`
**Level 2 (mid deps):** `graph` (→ parameterized), `query` (→ errors), `cast` (→ agtype)
**Level 3 (combined):** `filter` (→ query), `info` (→ Spark), `multitenancy` (→ info)
**Level 4 (transforms):** `transformers` (→ info), `verifiers` (→ Spark)
**Level 5 (top):** `data_layer` (→ ALL above), `manual_relationships/traverse` (→ info, multitenancy, cast, agtype, parameterized, telemetry, migration, errors, data_layer)

**Rule:** When modifying a module, you may import from same level or lower levels only. Never import from a higher level.

### Key Files by Purpose

| Purpose | Files |
|---------|-------|
| DataLayer entry point | `lib/data_layer.ex` |
| Edge CRUD changes | `lib/changes/create_edge.ex`, `lib/changes/destroy_edge.ex` |
| Traversal | `lib/manual_relationships/traverse.ex` (bounded variable-length manual relationship) |
| Raw Cypher | `AshAge.cypher/5` in `lib/ash_age.ex` (parameterized escape hatch) |
| Cypher generation | `lib/cypher/parameterized.ex`, `lib/query/filter.ex` |
| Type handling | `lib/type/agtype.ex`, `lib/type/cast.ex`, `lib/type/vertex.ex`, `lib/type/edge.ex`, `lib/type/path.ex` |
| DSL/Info | `lib/data_layer/info.ex`, `lib/edge.ex`, `lib/data_layer/transformers/*`, `lib/data_layer/verifiers/*` |
| Multitenancy | `lib/multitenancy.ex` (graph-name encoder), `lib/data_layer/verifiers/validate_multitenancy_attr.ex`, `AshAge.tenant_graph/2`, `AshAge.Migration.provision_tenant/3` |
| RLS (S6) | `AshAge.DataLayer.with_rls/4` + `unwrap_rls/2` (`lib/data_layer.ex`), `AshAge.DataLayer.Info.rls_guc/1` (`lib/data_layer/info.ex`), `AshAge.Migration.enable_tenant_rls/2,5` + `rls_ddl/4` + `validate_guc!/1` (`lib/migration.ex`), `lib/data_layer/verifiers/validate_multitenancy_attr.ex` (rls_guc invariants), `AshAge.with_tenant_rls/4` (`lib/ash_age.ex`), `mix ash_age.verify --resource` drift check (`lib/mix/tasks/ash_age.verify.ex`) |
| Telemetry | `lib/telemetry.ex` (value-free `[:ash_age, <op>]` span wrapper + metadata allowlist) |
| Graph lifecycle | `lib/graph.ex`, `lib/session.ex`, `lib/migration.ex` |
| Testing | `test/support/test_repo.ex`, `test/support/test_postgrex_types.ex`, `test/support/test_domain.ex`, `test/support/data_case.ex` |

## Critical Security Rules

**1. NEVER interpolate values into Cypher strings**

ALL dynamic values must go through `AshAge.Cypher.Parameterized.build/3` or `AshAge.Query.add_param/2`. This prevents Cypher injection.

**2. NEVER use AGE MERGE command**

MERGE has catastrophic performance bugs. Always use:
- For creates: `CREATE (n:Label) SET n.key = $val`
- For idempotent creates: `MATCH ... CREATE IF NOT EXISTS`

**3. ALWAYS validate identifiers**

User-provided graph names, labels, and property names must pass through `validate_identifier!/1` before use in Cypher.

**4. Search path order is critical**

Session.setup sets: `public, ag_catalog, "$user"` — public MUST come first to prevent `ag_catalog.schema_migrations` from shadowing Ecto's `public.schema_migrations`.

**5. NEVER echo raw values in errors or logs**

Filtered values and PostgreSQL error `DETAIL` lines can carry PII/secrets. Errors carry structure only — `UnsupportedFilter` the operator + field, DB failures the SQLSTATE code (+ constraint). Redact at the boundary with `AshAge.DataLayer.redact_db_error/1`; never `inspect` a filtered value or embed `Exception.message(%Postgrex.Error{})` in an error.

**6. RLS is a read-side backstop, NOT the write barrier — and requires a non-superuser DB role**

`rls_guc` enforcement (`with_rls/4`, `enable_tenant_rls/2,5`) is defense-in-depth
*beneath* Ash's app-layer `:attribute` tenant filter, not a replacement for it. AGE
`cypher()` `CREATE` **bypasses `WITH CHECK`** — a cross-tenant INSERT is not
RLS-denied at the database, so never treat RLS as the mechanism preventing a
cross-tenant write; that barrier is the `:attribute` force-set Ash core already
performs. RLS's job is DB-enforced read-confidentiality (and update/destroy
WHERE-targeting) for a connection whose GUC is wrong or unset. It only works when
the application's DB role is a **non-superuser without `BYPASSRLS`** — RLS
(`FORCE ROW LEVEL SECURITY` included) is silently skipped for superusers and
`BYPASSRLS` roles, with no error signal. Never point `rls_guc` at a resource served
by a superuser/BYPASSRLS connection and assume it is enforced.

## Common Patterns

### Adding a New Filter Operator

1. Add operator to `lib/query/filter.ex` in `do_translate/2`
2. Add test case to `test/ash_age/query/filter_test.exs`
3. Update `can?/2` in `lib/data_layer.ex` if new capability

### Adding DSL Configuration

1. Add field to `@age` DSL section in `lib/data_layer.ex`
2. Add accessor function to `lib/data_layer/info.ex`
3. Add transformer to `lib/data_layer/transformers/` if validation needed
4. Add transformer test to `test/ash_age/data_layer/transformers_test.exs`

## Testing Guidelines

**Always TDD:** Write test first, then implement.

**Integration vs Unit tests:**
- `test/ash_age/*_test.exs` — Unit tests (no PostgreSQL required)
- `test/integration/**/*_test.exs` — Integration tests, tagged `@moduletag :integration` (require running AGE)

**Running integration tests:** they are excluded unless `AGE_DATABASE_URL` points at a
live AGE database. `test_helper.exs` starts the test Repo (and sets `Sandbox` `:manual`
mode) only when that variable is set; otherwise the pure-unit suite runs with no database.
CI provides AGE and sets `AGE_DATABASE_URL`. Locally, run against an AGE container mapped
to a free host port, e.g. `AGE_DATABASE_URL=postgres://postgres:postgres@localhost:5462/ash_age_test mix test`.

**Async tests:** All AGE integration tests MUST use `async: false` — AGE doesn't support concurrent transactions.

**Test helpers:**
- `test/support/test_repo.ex` — Ecto.Repo (Postgres adapter) for AGE
- `test/support/test_postgrex_types.ex` — Postgrex types module registering the agtype extension
- `test/support/test_domain.ex` — shared Ash domain (`allow_unregistered? true`) for inline test resources
- `test/support/data_case.ex` — ExUnit case template: SQL Sandbox + `with_graph/3` (creates/drops a graph per test)

Integration-test resources are defined inline in their test modules (pointing `domain:` at
`AshAge.TestDomain`), so there is no shared `test_resources.ex`.

## Common Pitfalls

1. **Forgetting parameterization** — If you write `cypher <> value`, you're wrong. Use parameters.
2. **Missing error returns** — Unsupported operations MUST return `{:error, UnsupportedFilter}`
3. **Assuming Ash 2.x patterns** — Ash 3.x has different operator modules, no `Ash.Query.Value`
4. **Using ->> operator in indexes** — Must use `ag_catalog.agtype_access_operator()` because public comes before ag_catalog in search_path
5. **Assuming CREATE with $props works** — AGE doesn't support `CREATE (n:Label $props)` — must use `CREATE (n:Label) SET n.key = $val`

## When to Ask for Help

- Adding new Ash capabilities (aggregates, joins, etc.) — consult Ash Framework docs first
- Performance issues with Cypher queries — AGE has known limitations
- Graph schema changes — may require migration updates

## Version History

Key changes that affect agent behavior:
- Unreleased (S6): DB-enforced RLS. Opt-in, `:attribute`-only defense-in-depth: a
  `rls_guc "ash_age.tenant_id"` option in the `age` DSL block (`AshAge.DataLayer.Info.rls_guc/1`),
  guarded by a compile-time verifier requiring `:attribute` multitenancy and rejecting
  `global? true`. **`AshAge.Migration.enable_tenant_rls/2`** (resource-derived) and
  **`/5`** (explicit args) emit `ENABLE`/`FORCE ROW LEVEL SECURITY`, a functional btree
  index on the tenant discriminator, and a fail-closed **expression** policy over
  `properties` (`current_setting(guc, true) <> '' AND <attr> = current_setting(guc, true)`)
  — **never** a `GENERATED ALWAYS ... STORED` column (segfaults AGE `cypher()` writes on
  this build). All five CRUD callbacks (`read`/`create`/`update`/`destroy`/`bulk_create`)
  and traversal now route through **`AshAge.DataLayer.with_rls/4`** (`set_config`s the
  GUC inside `repo.transaction`, pinning one connection; off is a no-op; blank/nil tenant
  fails closed with `:rls_tenant_required` before any query) and **`unwrap_rls/2`**
  (normalizes the result back to the data-layer contract). `rls?` joins the telemetry
  value-free metadata allowlist. **`AshAge.with_tenant_rls/4`** is the auditable way to
  tenant-scope raw `AshAge.cypher/5` calls. `mix ash_age.verify --resource MyApp.Doc`
  gains a DSL-vs-DB drift check and the task now **exits non-zero** on any failing check
  (previously always exited 0). **Read-side/write-bypass reality:** AGE `cypher()` CREATE
  bypasses `WITH CHECK`, so RLS is a read-confidentiality (and update/destroy-targeting)
  backstop, NOT the write barrier — the `:attribute` app-layer force-set (Ash core) is
  the actual cross-tenant-write barrier. **Deployment constraint:** RLS is silently
  skipped for superusers and `BYPASSRLS` roles — the app's DB role must be neither, or
  the policy never applies with no error signal. Key files: `lib/data_layer.ex`
  (`with_rls/4`, `unwrap_rls/2`, `set_context/3`), `lib/migration.ex`
  (`enable_tenant_rls/2,5`, `rls_ddl/4`, `validate_guc!/1`), `lib/data_layer/info.ex`
  (`rls_guc/1`), `lib/data_layer/verifiers/validate_multitenancy_attr.ex`,
  `lib/mix/tasks/ash_age.verify.ex`.
- Unreleased (S5): Traversal + raw Cypher. **`AshAge.ManualRelationships.Traverse`** — bounded variable-length graph traversal as an Ash manual relationship (`manual {AshAge.ManualRelationships.Traverse, edge_label: :LINK, direction: :outgoing|:incoming|:both, min_depth: 1, max_depth: N}`). Returns an F3 source-PK-keyed map of materialized destination records, **deduped per source in Elixir** (by dest PK — no SQL `DISTINCT`, so `row_count` stays a genuine pre-dedup fan-out signal), cardinality-aware (`:one`/`:many`), all three directions including undirected `:both`, and single + composite primary keys. `max_depth` is required and bounded (unbounded `*` forbidden). Tenancy is **fail-closed**: `:context` → per-tenant graph; `:attribute` → per-node scoping via a **fixed-length UNION expansion** (one basic-`MATCH` branch per length in `min..max`, every node `<node>.<attr> = $tenant`-scoped, `UNION ALL`-joined) — **NOT** `ALL(n IN nodes(p) …)`, which this AGE build's Cypher parser rejects (probe P-S5b = NO; the UNION shape is P-S5b-UNION = YES). **`AshAge.cypher/5`** — parameterized raw-Cypher escape hatch (`AshAge.cypher(repo, graph, cypher, params \\ %{}, return_types)`): values reach AGE only as `$` params, `graph` is identifier-checked, `$$` break-out rejected; returns uniform decoded rows (`%{col_atom => %Vertex{}/%Edge{}/%Path{}/scalar}`) or `%AshAge.Errors.QueryFailed{}`. **Decode boundary:** a bare agtype aggregate (`collect(n)`, `{k: v}`) is returned as its raw agtype string (use `UNWIND`). Tenancy is **explicit** — the `graph` you pass is the isolation boundary; opens no transaction of its own. **Telemetry:** two new ops `:traverse` and `:cypher` join the `[:ash_age, <op>, :start | :stop | :exception]` span list; `:depth` is added to the value-free metadata allowlist (`:traverse` emits `destination_count`, `row_count`, `depth`, `direction`, `result`; `:cypher` emits `row_count`, `result`). **Data-layer fixes:** (1) the `In` filter now normalizes Ash's `MapSet` right side, so `filter(x in ^list)` and nested loads through traversal work (previously raised `UnsupportedFilter`); (2) `AshAge.Type.Path` decode now parses AGE's inline `::vertex`/`::edge`-tagged path wire format (previously raised `Jason.DecodeError`; first exercised by `cypher/5`'s `RETURN p`). Probes: P-S5a = YES (UNWIND + variable-length MATCH), P-S5b = NO, P-S5b-UNION = YES, P-S5c = YES (`IN $param` binds). Key file: `lib/manual_relationships/traverse.ex`.
- Unreleased (Telemetry): Data-layer telemetry spans. Every data-layer operation emits `[:ash_age, <op>, :start | :stop | :exception]` via `:telemetry.span` — ops are `:read`, `:create`, `:bulk_create`, `:update`, `:destroy`, `:create_edge`, `:destroy_edge`. Metadata is **value-free**: schema identifiers + counts/booleans/enums only (`resource`, `multitenancy`, `tenant?`, `stale?`, `properties?`, `direction`, `row_count`, `batch_size`, `group_count`, `destination_count`, `result`) — never a PK, property value, error reason, Cypher, or the tenant-derived `graph` name. `AshAge.Telemetry` (Level 0) owns the allowlist and RAISES on any off-allowlist key (the single R7 enforcement site). `:exception` fires only on a programmer/config raise (DB errors are returned as redacted `{:error, _}` tuples, surfacing as `:stop` with `result: :error`); its Erlang-standard `kind`/`reason`/`stacktrace` are intentionally outside the value-free contract. Pure addition — no callback return changed. (This makes real the `telemetry` reference that v0.2.5 had removed as a phantom.)
- Unreleased (S4): Edge CRUD + bulk create. **Edges:** `AshAge.Changes.CreateEdge` and `AshAge.Changes.DestroyEdge` change modules run parameterized edge Cypher in `after_action`, inside the action's transaction, with optional edge properties (values from same-named action arguments, type-serialized identically to vertex attrs), atomic write (0-row edge → `InvalidRelationship`, rolled back; DB errors redacted), tenant-scoped endpoints (`:context` same-graph fail-closed, `:attribute` both endpoints scoped by tenant discriminator). `:both` direction stored `:outgoing`, readable via undirected match (S5 contract pinned by integration test). Destination resources require single-attribute PK. **Bulk create:** `can?(:bulk_create) → true`; `bulk_create/3` emits `UNWIND $rows AS row CREATE (n:Label) SET …` per key-set group (no null-fill divergence from single-create), order-preserving on `return_records?: true`, binary/date round-trip via `$age64$`/ISO8601, atomic-per-batch (later-group failure rolls back earlier under `transaction: :batch`, partial write possible under `transaction: false`), `:context` nil tenant fails closed. Edge-label auto-create on `CREATE` (AGE behavior, verified live by probe P4); labels provisioned via `create_edge_label/2` migration or `provision_tenant/3` `:elabels` per tenant. Key files: `lib/changes/create_edge.ex`, `lib/changes/destroy_edge.ex`, `lib/data_layer/verifiers/validate_edge.ex`.
- Unreleased (S3): Multitenancy. `:attribute` (Ash-core-handled) gains a fail-closed compile verifier (`AshAge.DataLayer.Verifiers.ValidateMultitenancyAttr`: the multitenancy attribute must not be in `age skip`). `:context` = graph-per-tenant: `can?(:multitenancy) → true`, `set_tenant/3` overwrites `query.graph`, writes resolve the graph from `changeset.to_tenant` (fail-closed on nil), `AshAge.Multitenancy.graph_name/2` two-branch collision-free encoder (+ `tenant_graph` MFA override, `AshAge.tenant_graph/2` shim), `AshAge.Migration.provision_tenant/3` idempotent runtime provisioner. **Security:** `can?(:changeset_filter) → true` and `update`/`destroy` now honor `changeset.filter` (translate it into the WHERE, fail-closed on untranslatable) — closes a cross-tenant write/delete where mutations matched by PK only and dropped Ash's tenant/policy scoping; also applies `Ash.Policy` filters to mutations. **Behavior change:** `update/2` and `destroy/2` return `Ash.Error.Changes.StaleRecord` (not `NotFound`) on a 0-row PK+scoping match — the Ash contract for record-based mutations (matches the reference ETS data layer + Ash core; `NotFound` is for identifier lookups and would miss Ash's bulk StaleRecord handling). `destroy/2` uses `RETURN n` to detect the 0-row case (was unconditional `:ok`). `:context` integration tests provision graphs unboxed and drop them in `setup_all`'s `on_exit` (a per-test `on_exit` drop deadlocks against the Sandbox owner transaction).
- Unreleased (S2): Composite / non-`:id` primary keys in update/destroy (matched on the row's ORIGINAL key, so renaming a writable PK works). `:binary`/AshCloak round-trip via a self-identifying `"$age64$"`-tagged base64 wire format (`AshAge.Type.Cast.encode_binary/1` is the single source of truth; untagged/legacy values pass through undecoded). Error-message value redaction (operator/field + SQLSTATE only; non-Postgrex errors also redacted, never crash).
- v0.2.5: Removed phantom references to non-existent modules (`traversal.ex`, `telemetry`) and features (`traverse`, `neighbors`, `find_path`, depth limits) from all docs. Updated README install version.
- v0.2.4: Fixed UUID primary key overwrite by AGE integer ID (`Map.put` → `Map.put_new`). Removed `NULL` third arg from static Cypher queries (AGE rejects it).
- v0.2.3: Added Postgrex wire protocol length prefix to `AgtypeExtension` encode/decode — required for proper parameter framing.
- v0.2.2: Fixed `AgtypeExtension.encode/1` returning `{:ok, value}` tuple instead of raw binary. Added missing `rollback/2` callback to DataLayer.
- v0.2.1: Fixed error struct field mismatches in data_layer.ex (`:message`/`:detail` → `:reason`; `:resource` → `:query` for QueryFailed). Removed phantom `TraversalDepthExceeded` from docs.
- v0.2.0: Core data pipeline — real agtype parser, vertex-to-resource casting, DSL transformer validation, idempotent migrations, parameterized Cypher
- v0.1.0: Initial release with CRUD, filter, sort, limit/offset
- Removed MERGE support due to AGE bugs (use CREATE + SET)
- Added search_path: `public, ag_catalog, "$user"` to fix schema_migrations shadowing
- Fixed index SQL to use `ag_catalog.agtype_access_operator()` for agtype properties
