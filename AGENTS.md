# AshAge - AI Agent Development Guide

This file helps AI agents (Claude Code, GitHub Copilot Workspace, etc.) work effectively with ash_age codebase.

## Architecture Overview

AshAge is an Ash Framework DataLayer for Apache AGE graph database. It translates Ash queries into Cypher (AGE's query language) and manages graph vertices/edges through PostgreSQL's AGE extension.

### Module Dependency Levels

When making changes, understand these dependency levels:

**Level 0 (no deps):** `errors`, `vertex`, `edge`, `path`, `session`, `migration`, `telemetry`, `graph`
**Level 1 (leaf deps):** `agtype` (→ vertex,edge,path), `parameterized` (→ errors, migration), `agtype_extension`
**Level 2 (mid deps):** `query` (→ errors, migration), `cast` (→ agtype), `cypher/expr` (→ errors, cast)
**Level 3 (combined):** `filter` (→ query, cast), `query/aggregate` (→ query, migration), `info` (→ Spark), `multitenancy` (→ info, migration)
**Level 4 (transforms):** `transformers` (→ info, migration), `verifiers` (→ Spark, cast, info)
**Level 5 (top):** `data_layer` (→ ALL above), `changes/*` (→ data_layer, info, migration, cast, telemetry), `manual_relationships/traverse` (→ info, multitenancy, cast, agtype, parameterized, telemetry, migration, errors, data_layer), `ash_age` (→ data_layer), `mix/tasks/*` (→ data_layer, migration, info)

**Rule:** When modifying a module, you may import from same level or lower levels only. Never import from a higher level. (`Cypher.Expr` uses `Type.Cast` — both Level 2 — for typed literal serialization; legal same-level.)

### Key Files by Purpose

| Purpose | Files |
|---------|-------|
| DataLayer entry point | `lib/data_layer.ex` |
| Edge CRUD changes | `lib/changes/create_edge.ex`, `lib/changes/destroy_edge.ex`, `lib/changes/edge_cypher.ex` |
| Traversal | `lib/manual_relationships/traverse.ex` (bounded variable-length manual relationship) |
| Raw Cypher | `AshAge.cypher/5` in `lib/ash_age.ex` (parameterized escape hatch) |
| Cypher generation | `lib/cypher/parameterized.ex`, `lib/cypher/expr.ex`, `lib/query.ex`, `lib/query/filter.ex`, `lib/query/aggregate.ex` |
| Type handling | `lib/type/agtype.ex`, `lib/type/cast.ex` (THE storage-class/serialize home), `lib/type/vertex.ex`, `lib/type/edge.ex`, `lib/type/path.ex` |
| DSL/Info | `lib/data_layer/info.ex`, `lib/edge.ex`, `lib/data_layer/transformers/*`, `lib/data_layer/verifiers/*` |
| Multitenancy | `lib/multitenancy.ex` (graph-name encoder), `lib/data_layer/verifiers/validate_multitenancy_attr.ex`, `AshAge.tenant_graph/2`, `AshAge.Migration.provision_tenant/3` |
| RLS | `AshAge.DataLayer.with_rls/4` + `unwrap_rls/2` (`lib/data_layer.ex`), `AshAge.DataLayer.Info.rls_guc/1`, `AshAge.Migration.enable_tenant_rls/2,5` + `rls_ddl/4` + `validate_guc!/1`, `AshAge.with_tenant_rls/4`, `mix ash_age.verify --resource` |
| Sensitive classification | `lib/data_layer/verifiers/validate_sensitive.ex`, `lib/data_layer/verifiers/validate_skip.ex`, `AshAge.DataLayer.Info.sensitive/1`, `AshAge.Type.Cast.binary_storage?/2` + `Cast.serialize_value/2` (the ONE predicate/encoder), runtime guard in `AshAge.Changes.CreateEdge.edge_properties/2` |
| Telemetry | `lib/telemetry.ex` (value-free `[:ash_age, <op>]` span wrapper + metadata-key allowlist) |
| Graph lifecycle | `lib/graph.ex`, `lib/session.ex`, `lib/migration.ex` |
| Testing | `test/support/test_repo.ex`, `test/support/test_postgrex_types.ex`, `test/support/test_domain.ex`, `test/support/data_case.ex` |

## Critical Security Rules

**1. NEVER interpolate values into Cypher strings**

ALL dynamic values must go through `AshAge.Cypher.Parameterized.build/3` or `AshAge.Query.add_param/2`. This prevents Cypher injection.

**2. NEVER use AGE MERGE command**

MERGE has catastrophic performance bugs. Always use:
- For creates: `CREATE (n:Label) SET n.key = $val`
- For idempotent creates / upserts: the two-statement existence-MATCH-then-CREATE/SET path (`do_upsert`)

**3. ALWAYS validate identifiers — and backtick-quote every property ref**

User-provided graph names, labels, and property names must pass `AshAge.Migration.validate_identifier!/1` (or its predicate `identifier?/1`) before use, and every property reference in emitted Cypher is backtick-quoted (`` n.`attr` ``) — a bare `n.count` is an AGE syntax error for Cypher-keyword attribute names. The MERGE ban and search_path order have mutation-proven invariant tests (`test/integration/no_merge_test.exs`, `test/integration/session_search_path_test.exs`); keep them green.

**4. Search path order is critical**

Session.setup sets: `public, ag_catalog, "$user"` — public MUST come first to prevent `ag_catalog.schema_migrations` from shadowing Ecto's `public.schema_migrations`.

**5. NEVER echo raw values in errors or logs**

Filtered values and PostgreSQL error `DETAIL` lines can carry PII/secrets. Errors carry structure only — `UnsupportedFilter` the operator + field, DB failures the SQLSTATE code (+ constraint). Redact at the boundary with `AshAge.DataLayer.redact_db_error/1`; `QueryFailed`/`UpdateFailed.message/1` structurally redact `%Postgrex.Error{}` reasons; never `inspect` a filtered value or embed `Exception.message(%Postgrex.Error{})` in an error. An untranslatable filter expression FAILS CLOSED (`validate_expression` on the read/aggregate/destroy/update paths) — it is never silently dropped.

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

### Adding a New Filter Operator / Function

1. Add the clause to `do_translate/2` in `lib/query/filter.ex` (see the string-predicate clauses for the shape: cast the value, backtick the ref, fail closed on untranslatable semantics — e.g. `:ci_string` rejects)
2. Add the matching `can?(_, {:filter_expr, %Struct{}})` clause in `lib/data_layer.ex`, then check dispatch coupling (`grep -rn "data_layer_can?\|{:filter_expr" deps/ash/lib`) — every new `can?` clause can reroute an Ash dispatch path
3. Add tests to `test/ash_age/query/filter_test.exs` (unit shape) and an integration case

### Adding DSL Configuration

1. Add field to the `@age` DSL section in `lib/data_layer.ex`
2. Add accessor function to `lib/data_layer/info.ex`
3. Add transformer to `lib/data_layer/transformers/` if validation needed (use `AshAge.Migration.identifier?/1` — never re-declare the regex)
4. Add transformer test to `test/ash_age/data_layer/transformers_test.exs` (transformer DslErrors RAISE out of `defmodule` — use `assert_raise`; verifier errors need `Spark.Test`'s `assert_dsl_error`/`refute_dsl_errors` collectors)

## Testing Guidelines

**Always TDD:** Write test first, watch it RED for the right reason, then implement.

**Integration vs Unit tests:**
- `test/ash_age/*_test.exs` — Unit tests (no PostgreSQL required)
- `test/integration/**/*_test.exs` — Integration tests, tagged `@moduletag :integration` (require running AGE)

**Running integration tests:** excluded unless `AGE_DATABASE_URL` points at a live AGE database; `test_helper.exs` starts the test Repo only when that variable is set. CI provides AGE and sets `AGE_DATABASE_URL`. Locally: load the shared server's URL from the gitignored `.env` (`set -a; . ./.env; set +a`), or run an AGE container mapped to a free host port. If the URL is unset, force the unit lane with `env -u AGE_DATABASE_URL mix test` (an empty-string value is truthy and wrongly runs the integration lane against nothing).

**Async tests:** All AGE integration tests MUST use `async: false` — AGE doesn't support concurrent transactions. `with_graph/3` wraps the WHOLE test body (create graph → fun → drop); using it in `setup` drops the graph before tests run.

**Test helpers:** `test/support/data_case.ex` (SQL Sandbox + `with_graph/3` + `cypher_query/3` + `exec/1`), `test/support/test_repo.ex`, `test/support/test_domain.ex` (`allow_unregistered? true` for inline test resources).

## Common Pitfalls

1. **Forgetting parameterization** — If you write `cypher <> value`, you're wrong. Use parameters.
2. **Missing error returns** — Unsupported operations MUST return `{:error, UnsupportedFilter}` / `UnsupportedExpression`
3. **Assuming Ash 2.x patterns** — Ash 3.x has different operator modules, no `Ash.Query.Value`
4. **Using ->> operator in indexes** — Must use `ag_catalog.agtype_access_operator()` because public comes before ag_catalog in search_path
5. **Assuming CREATE with $props works** — AGE doesn't support `CREATE (n:Label $props)` — must use `CREATE (n:Label) SET n.key = $val`
6. **Passing a repo to `Session.setup/1`** — it takes a raw DBConnection (it's an `after_connect` hook)
7. **Nested `with_graph`** — leaks graphs when a body fails mid-run; provision multi-graph tests with one `unboxed_run` + `try/after`
8. **AGE `cypher()`'s graph argument is a string literal** — it cannot be a `$param`; that's why `Parameterized` interpolates a validated identifier

## Version History

Full history in [CHANGELOG.md](CHANGELOG.md). Summary of agent-relevant shifts:

- **2.1.0:** Every property ref backtick-quoted (Cypher-keyword attrs work on all paths); read path fails closed on untranslatable expressions; string predicates (contains/starts_with/ends_with, case-sensitive) on reads; mixed-tenant `:context` bulk batches fail closed; `with_tenant_rls` rollback reasons preserved; error messages structurally redact driver errors; edge tenant honors `parse_attribute`; identifier regex single-homed in `Migration.identifier?/1`; OTP 27+28 CI matrix; MERGE-ban + search_path-order invariant tests (mutation-proven).
- **2.0.0:** Atomic-aware updates (`Ash.Expr` → Cypher via `update_query/4`/`update_many/3`, `lib/cypher/expr.ex`); `bulk_destroy`/`bulk_update` with a query REQUIRE the tenant on the QUERY (`Ash.Query.set_tenant/2`); keyword-attr backtick fix landed for filter/sort/SET (`prop_ref/1`); `can?` advertisement is load-bearing dispatch — grep `data_layer_can?` in `deps/ash/lib/ash/actions/` before changing any clause. Known Ash interaction: `Ash.update_many/4` without `return_records?: true` raises `BadBooleanError` (Ash-side strict-`or` contract).
- **1.0.1:** Getting-started Livebook guide.
- **1.0.0:** Sensitive-data classification (`sensitive`/`skip` verifiers, `Cast.storage_class/2` the single type home, `serialize_value/2` the single encoder, `$age64$` binary wire form, value-free JSON boundary); DB-enforced RLS (opt-in `rls_guc`, `with_rls/4`, `enable_tenant_rls`, `mix ash_age.verify` exits non-zero); traversal + raw `AshAge.cypher/5`; edge CRUD + bulk create; multitenancy `:attribute`/`:context` (record-based 0-row scoped mutations return StaleRecord, not NotFound); telemetry value-free spans; composite / non-`:id` primary keys.
- **0.2.x:** Core data pipeline (agtype parser, parameterized Cypher, idempotent migrations), Postgrex wire-protocol fixes, phantom-reference cleanup, MERGE removal (AGE bugs), search_path fix, index SQL via `ag_catalog.agtype_access_operator()`.

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
