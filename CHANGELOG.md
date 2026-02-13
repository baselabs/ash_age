# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/baselabs/ash_age/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/baselabs/ash_age/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/baselabs/ash_age/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/baselabs/ash_age/releases/tag/v0.1.0
