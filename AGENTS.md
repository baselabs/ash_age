# AshAge

## Architecture Overview

AshAge is an Ash Framework DataLayer for Apache AGE graph database. It translates Ash queries into Cypher (AGE's query language) and manages graph vertices/edges through PostgreSQL's AGE extension.

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

**6. RLS is a read-side backstop, not the write barrier, and needs a non-superuser role**

`rls_guc` enforcement (`with_rls/4`, `enable_tenant_rls/2,5`) sits beneath Ash's
`:attribute` tenant filter and does not replace it. AGE `cypher()` `CREATE` bypasses
`WITH CHECK`, so a cross-tenant insert is stopped by the tenant attribute Ash sets,
not by RLS. RLS protects reads and update/destroy targeting when the GUC is wrong or
unset. PostgreSQL skips RLS silently for superusers and `BYPASSRLS` roles, so the
application's role must be neither.

**7. Publishing, deploying and pushes to mirrors need the owner's approval for that action.**

## Build and test

Commands run from the repository root on the toolchain in `.tool-versions`: the first version of
each tool is the default, and every other Elixir build, paired with its Erlang by OTP major, is a
compatibility lane CI also runs.

- **Build.** `mix compile --warnings-as-errors`.
- **Covering tests.** `mix test <paths>` for the changed files and their direct
  dependents. Unit tests (`test/ash_age/`) need no database: run them with
  `env -u AGE_DATABASE_URL mix test <paths>` or `mix test.unit`. Integration tests
  (`test/integration/`, `@moduletag :integration`) run only when `AGE_DATABASE_URL`
  points at a live AGE database; `test/test_helper.exs` starts the test Repo whenever
  the variable is set, even to an empty string. Load it from the gitignored `.env`
  (`set -a; . ./.env; set +a`).
- **Before a push.** `mix precommit`, in the test environment: format check, compile with warnings
  as errors (test support included), `credo --strict`, the unused-lock check, the documentation
  build and the suite (integration tests only where `AGE_DATABASE_URL` is set). Not Dialyzer.
- **Exceptions.** Notebook: `elixir scripts/run_notebook.exs notebooks/getting_started.livemd`
  with `AGE_DATABASE_URL` and `ASH_AGE_SRC` set. DSL docs: `mix run scripts/gen_dsl_cheatsheet.exs`.
- **Landing.** A commit reaches `master` only after CI's run on its landing branch is green.
- **CI.** One `ci.yml`. On the default toolchain: lint (format, `credo --strict`, the unused-lock
  check, `hex.audit`), compile and docs, the suite with AGE, Dialyzer and the notebook. On every
  compatibility lane: compile, the suite with AGE and Dialyzer. On the floor toolchain in
  `ci/floor/.tool-versions`: the runtime dependencies resolved fresh and compiled with warnings as
  errors. Raising the floor changes `elixir` in `mix.exs`, that file and CONTRIBUTING.md together.

## Testing Guidelines

- AGE integration tests use `async: false`; AGE does not support concurrent
  transactions.
- `with_graph/3` wraps the whole test body (create graph, run, drop). Calling it in
  `setup` drops the graph before the tests run.
- Helpers: `test/support/data_case.ex` (SQL Sandbox, `with_graph/3`, `cypher_query/3`,
  `exec/1`), `test/support/test_repo.ex`, `test/support/test_domain.ex`
  (`allow_unregistered? true` for inline test resources).
