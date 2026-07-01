# AshAge - AI Agent Development Guide

This file helps AI agents (Claude Code, GitHub Copilot Workspace, etc.) work effectively with ash_age codebase.

## Architecture Overview

AshAge is an Ash Framework DataLayer for Apache AGE graph database. It translates Ash queries into Cypher (AGE's query language) and manages graph vertices/edges through PostgreSQL's AGE extension.

### Module Dependency Levels

When making changes, understand these dependency levels:

**Level 0 (no deps):** `errors`, `vertex`, `edge`, `path`, `session`, `migration`
**Level 1 (leaf deps):** `agtype` (→ vertex,edge,path), `parameterized` (→ errors), `agtype_extension`
**Level 2 (mid deps):** `graph` (→ parameterized), `query` (→ errors), `cast` (→ agtype)
**Level 3 (combined):** `filter` (→ query), `info` (→ Spark), `multitenancy` (→ info)
**Level 4 (transforms):** `transformers` (→ info), `verifiers` (→ Spark)
**Level 5 (top):** `data_layer` (→ ALL above)

**Rule:** When modifying a module, you may import from same level or lower levels only. Never import from a higher level.

### Key Files by Purpose

| Purpose | Files |
|---------|-------|
| DataLayer entry point | `lib/data_layer.ex` |
| Cypher generation | `lib/cypher/parameterized.ex`, `lib/query/filter.ex` |
| Type handling | `lib/type/agtype.ex`, `lib/type/cast.ex`, `lib/type/vertex.ex`, `lib/type/edge.ex`, `lib/type/path.ex` |
| DSL/Info | `lib/data_layer/info.ex`, `lib/edge.ex`, `lib/data_layer/transformers/*`, `lib/data_layer/verifiers/*` |
| Multitenancy | `lib/multitenancy.ex` (graph-name encoder), `lib/data_layer/verifiers/validate_multitenancy_attr.ex`, `AshAge.tenant_graph/2`, `AshAge.Migration.provision_tenant/3` |
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
