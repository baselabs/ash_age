# AshAge - AI Agent Development Guide

This file helps AI agents (Claude Code, GitHub Copilot Workspace, etc.) work effectively with ash_age codebase.

## Architecture Overview

AshAge is an Ash Framework DataLayer for Apache AGE graph database. It translates Ash queries into Cypher (AGE's query language) and manages graph vertices/edges through PostgreSQL's AGE extension.

### Module Dependency Levels

When making changes, understand these dependency levels:

**Level 0 (no deps):** `errors`, `vertex`, `edge`, `path`, `session`, `migration`, `telemetry`
**Level 1 (leaf deps):** `agtype` (→ vertex,edge,path), `parameterized` (→ errors)
**Level 2 (mid deps):** `graph` (→ parameterized), `query` (→ errors), `cast` (→ agtype)
**Level 3 (combined):** `filter` (→ query), `traversal` (→ parameterized), `info` (→ Spark)
**Level 4 (transforms):** `transformers` (→ info)
**Level 5 (top):** `data_layer` (→ ALL above)

**Rule:** When modifying a module, you may import from same level or lower levels only. Never import from a higher level.

### Key Files by Purpose

| Purpose | Files |
|---------|-------|
| DataLayer entry point | `lib/data_layer.ex` |
| Cypher generation | `lib/cypher/parameterized.ex`, `lib/query/filter.ex`, `lib/cypher/traversal.ex` |
| Type handling | `lib/type/agtype.ex`, `lib/type/cast.ex`, `lib/type/vertex.ex`, `lib/type/edge.ex`, `lib/type/path.ex` |
| DSL/Info | `lib/data_layer/info.ex`, `lib/edge.ex`, `lib/data_layer/transformers/*` |
| Graph lifecycle | `lib/graph.ex`, `lib/session.ex`, `lib/migration.ex` |
| Testing | `test/support/test_repo.ex`, `test/support/test_resources.ex` |

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

## Common Patterns

### Adding a New Filter Operator

1. Add operator to `lib/query/filter.ex` in `do_translate/2`
2. Add test case to `test/ash_age/query/filter_test.exs`
3. Update `can?/2` in `lib/data_layer.ex` if new capability

### Adding a New Traversal Pattern

1. Add function to `lib/cypher/traversal.ex`
2. Generate Cypher with `build/4` pattern for parameterization
3. Add test to `test/ash_age/cypher/traversal_test.exs`
4. Wire to DataLayer actions if exposing as Ash action

### Adding DSL Configuration

1. Add field to `@age` DSL section in `lib/data_layer.ex`
2. Add accessor function to `lib/data_layer/info.ex`
3. Add transformer to `lib/data_layer/transformers/` if validation needed
4. Add transformer test to `test/ash_age/data_layer/transformers_test.exs`

## Testing Guidelines

**Always TDD:** Write test first, then implement.

**Integration vs Unit tests:**
- `test/ash_age/*_test.exs` — Unit tests (no PostgreSQL required)
- `test/integration/*_test.exs` — Integration tests (require running AGE)

**Async tests:** All AGE integration tests MUST use `async: false` — AGE doesn't support concurrent transactions.

**Test helpers:**
- `test/support/test_repo.ex` — Ecto.Repo with AGE setup
- `test/support/test_resources.ex` — Sample Ash resources using AshAge.DataLayer

## Common Pitfalls

1. **Forgetting parameterization** — If you write `cypher <> value`, you're wrong. Use parameters.
2. **Breaking depth limits** — Traversal depth MUST be capped (4 real-time, 6 background)
3. **Missing error returns** — Unsupported operations MUST return `{:error, UnsupportedFilter}`
4. **Assuming Ash 2.x patterns** — Ash 3.x has different operator modules, no `Ash.Query.Value`
5. **Using ->> operator in indexes** — Must use `ag_catalog.agtype_access_operator()` because public comes before ag_catalog in search_path
6. **Assuming CREATE with $props works** — AGE doesn't support `CREATE (n:Label $props)` — must use `CREATE (n:Label) SET n.key = $val`

## When to Ask for Help

- Adding new Ash capabilities (aggregates, joins, etc.) — consult Ash Framework docs first
- Performance issues with Cypher queries — AGE has known limitations
- Graph schema changes — may require migration updates

## Version History

Key changes that affect agent behavior:
- v0.1.0: Initial release with CRUD, filter, traversal
- Removed MERGE support due to AGE bugs (use CREATE + SET)
- Added search_path: `public, ag_catalog, "$user"` to fix schema_migrations shadowing
- Fixed index SQL to use `ag_catalog.agtype_access_operator()` for agtype properties
