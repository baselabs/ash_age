# Troubleshooting

The sharp edges specific to running Ash on Apache AGE. Each entry is
symptom → cause → fix.

## Row-Level Security appears to do nothing

**Symptom.** You enabled `rls_guc` and ran `enable_tenant_rls/2`, but every
tenant still sees every row.

**Cause.** PostgreSQL **silently skips RLS** — including `FORCE ROW LEVEL
SECURITY` — for superusers and for any role with the `BYPASSRLS` attribute. No
error is raised; the policy simply never applies.

**Fix.** Run the application under a **non-superuser role without `BYPASSRLS`**.
RLS is a defense-in-depth backstop, not the primary tenant filter — the
`:attribute` app-layer scoping (Ash core's tenant filter + force-set) is the
actual isolation boundary; RLS only adds a DB-enforced read barrier beneath it.

## `cypher()` writes crash the connection (signal 11)

**Symptom.** A create/update against a label table crashes Postgres with a
segfault and connection recovery.

**Cause.** A `GENERATED ALWAYS ... STORED` generated column on an AGE label
table **segfaults every `cypher()` write** on the supported AGE build.

**Fix.** Never add a stored generated column to a label table. `ash_age`'s RLS
migration deliberately uses a **live expression policy** over `properties`
(`current_setting(guc, true) <> '' AND <discriminator> = current_setting(guc,
true)`), never a generated column — keep it that way if you hand-edit RLS DDL.

## A cross-tenant edge/vertex was created despite RLS

**Symptom.** RLS is on, yet a `CREATE` wrote a row scoped to another tenant.

**Cause.** AGE `cypher()` **`CREATE` bypasses `WITH CHECK`** — RLS is
read/target-side only. A cross-tenant INSERT is not denied at the database.

**Fix.** This is expected. The write barrier for `:attribute` multitenancy is
Ash core's force-set of the tenant attribute, not RLS. Do not rely on RLS to
reject cross-tenant writes; rely on it to hide cross-tenant reads.

## Every `update`/`destroy` returns `StaleRecord`

**Symptom.** A resource's mutations always fail with
`Ash.Error.Changes.StaleRecord`, even for rows that exist.

**Cause.** The primary-key attribute is listed in `age do skip [...] end`, so the
PK is never written as a graph property and the `WHERE` matches zero rows. As of
the current version this is a compile-time verifier error (`ValidateSkip`), but
on an older build it fails silently at runtime.

**Fix.** Remove the primary key from `skip`. Compile with `--warnings-as-errors`
so the verifier is build-blocking (see below).

## A misconfiguration compiles anyway

**Symptom.** A `sensitive` attribute that isn't binary-storage-typed, a PK in
`skip`, or a binary multitenancy discriminator compiles without failing.

**Cause.** Spark surfaces verifier `DslError`s as **compiler warnings**, not
hard failures — a plain `mix compile` prints the warning and still builds the
module. This is ecosystem-wide Spark behavior.

**Fix.** Build with `mix compile --warnings-as-errors` (standard CI practice) to
make every verifier rule build-blocking.

## `Jason.EncodeError` / bytes in an error message

**Symptom.** A create/update raised `Jason.EncodeError`, or an error message
appeared to contain raw value bytes.

**Cause.** Raw non-UTF-8 bytes nested **inside a `:map`/`:list`** attribute value
are not JSON-encodable (the AGE property substrate is JSON; AshPostgres `jsonb`
has the same limit). Top-level `:binary` attributes are fine — `ash_age`
`$age64$`-tags them automatically.

**Fix.** Encode nested bytes app-side (`Base.encode64/1`) or store them in a
top-level `:binary` attribute. On the current version this fails closed with a
value-free error naming the attribute rather than raising.

## A `:binary` field won't sort or range-filter

**Symptom.** `sort(field: :asc)` raises `Ash.Error.Query.UnsortableField`, and
`>`/`<`/`>=`/`<=` return `UnsupportedFilter`.

**Cause.** Binary-storage values are stored as `$age64$`-tagged base64, which is
**not byte-order-preserving** — sorting or range-comparing the stored form would
return silently wrong results, so both are rejected by design.

**Fix.** `eq`/`not_eq`/`in` work (deterministic-encryption search). If you need
ordering or ranges, keep a separate plaintext/orderable companion attribute.

## Legacy binary rows are readable but not matchable

**Symptom.** Rows whose `:binary` values were written before this format (or
out-of-band) read back fine, but filters and updates against them match nothing.

**Cause.** Match params (filters, PK match, traversal, edge endpoints) send the
tagged `$age64$` form; untagged stored values are returned verbatim on read
(read-only grace) but never re-tagged, so they don't match.

**Fix.** Rewrite the property through `ash_age` (a create/update re-tags it), or
store such values as `:string`.

## `datetime()` fails in raw Cypher

**Symptom.** `AshAge.cypher/5` with `RETURN datetime()` errors with
`function datetime does not exist`.

**Cause.** The supported AGE build (1.6.0) does not implement `datetime()`.

**Fix.** Use `timestamp()` (epoch milliseconds) in Cypher, or handle
date/datetime app-side — `ash_age` serializes `%Date{}`/`%DateTime{}` to ISO8601
on write and coerces them back on read (including `Ash.Type.NewType` wrappers).

## Index or property access fails with an operator error

**Symptom.** A migration index or a hand-written query using `->>` against a
label table errors or silently reads nothing.

**Cause.** `public` precedes `ag_catalog` in the default `search_path`, so the
bare `->>` operator can resolve to the wrong function.

**Fix.** Use the fully-qualified `ag_catalog.agtype_access_operator(...)` in
index SQL (the `create_vertex_index/3` helper does this for you).
