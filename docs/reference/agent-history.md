# Agent instruction history

Text moved byte-for-byte out of `AGENTS.md` on October 28, 2026, when the owner ruled that
process is sized to the risk of each change. Historical record only; not binding.

## From AGENTS.md: Testing Guidelines (superseded blanket rule)

**Always TDD:** Write test first, watch it RED for the right reason, then implement.

## From AGENTS.md (whole section)

## Version History

Full history in [CHANGELOG.md](CHANGELOG.md). Summary of agent-relevant shifts:

- **2.1.0:** Every property ref backtick-quoted (Cypher-keyword attrs work on all paths); read path fails closed on untranslatable expressions; string predicates (contains/starts_with/ends_with, case-sensitive) on reads; mixed-tenant `:context` bulk batches fail closed; `with_tenant_rls` rollback reasons preserved; error messages structurally redact driver errors; edge tenant honors `parse_attribute`; identifier regex single-homed in `Migration.identifier?/1`; OTP 27+28 CI matrix; MERGE-ban + search_path-order invariant tests (mutation-proven).
- **2.0.0:** Atomic-aware updates (`Ash.Expr` → Cypher via `update_query/4`/`update_many/3`, `lib/cypher/expr.ex`); `bulk_destroy`/`bulk_update` with a query REQUIRE the tenant on the QUERY (`Ash.Query.set_tenant/2`); keyword-attr backtick fix landed for filter/sort/SET (`prop_ref/1`); `can?` advertisement is load-bearing dispatch — grep `data_layer_can?` in `deps/ash/lib/ash/actions/` before changing any clause. Known Ash interaction: `Ash.update_many/4` without `return_records?: true` raises `BadBooleanError` (Ash-side strict-`or` contract).
- **1.0.1:** Getting-started Livebook guide.
- **1.0.0:** Sensitive-data classification (`sensitive`/`skip` verifiers, `Cast.storage_class/2` the single type home, `serialize_value/2` the single encoder, `$age64$` binary wire form, value-free JSON boundary); DB-enforced RLS (opt-in `rls_guc`, `with_rls/4`, `enable_tenant_rls`, `mix ash_age.verify` exits non-zero); traversal + raw `AshAge.cypher/5`; edge CRUD + bulk create; multitenancy `:attribute`/`:context` (record-based 0-row scoped mutations return StaleRecord, not NotFound); telemetry value-free spans; composite / non-`:id` primary keys.
- **0.2.x:** Core data pipeline (agtype parser, parameterized Cypher, idempotent migrations), Postgrex wire-protocol fixes, phantom-reference cleanup, MERGE removal (AGE bugs), search_path fix, index SQL via `ag_catalog.agtype_access_operator()`.
