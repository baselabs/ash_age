# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

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
- Error messages no longer leak filtered values or database row contents.
  `AshAge.Errors.UnsupportedFilter` now reports only the operator and referenced
  field name (never the filtered value). `CreateFailed`/`QueryFailed`/`UpdateFailed`
  surface only the PostgreSQL SQLSTATE code (and constraint name), never the
  Postgres `DETAIL` line that echoes offending values. A regression test pins the
  never-interpolate guarantee: values reach Cypher only as the `$1` parameter.

### Fixed

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
  `Jason.encode!` on create/update. Binary values are base64-encoded for AGE
  storage and decoded back on read; plaintext strings are untouched.

### Added

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

[Unreleased]: https://github.com/baselabs/ash_age/compare/v0.2.6...HEAD
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
