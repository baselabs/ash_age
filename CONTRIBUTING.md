# Contributing to AshAge

## Prerequisites

- **Elixir** and **Erlang/OTP** as pinned in `.tool-versions` (the first version of each is the
  default). The package supports Elixir 1.17+ on Erlang/OTP 26+; CI proves that floor.
- **PostgreSQL** with the [Apache AGE](https://age.apache.org/) extension. CI tests
  PostgreSQL 16 with AGE 1.6.0.
- Run `CREATE EXTENSION IF NOT EXISTS age;` in your test database.

## Getting Started

```bash
git clone https://github.com/baselabs/ash_age.git
cd ash_age
mix deps.get
mix test
```

`mix test` runs the unit tests with no database. Set `AGE_DATABASE_URL` to a live AGE
database to run the integration tests as well:

```bash
docker compose up -d
AGE_DATABASE_URL=postgres://postgres:postgres@localhost:5462/ash_age_test mix test.integration
```

An empty `AGE_DATABASE_URL` still counts as set and starts the test Repo. For a run with
no database, unset it: `env -u AGE_DATABASE_URL mix test`.

## Checks

```bash
mix format             # Format code
mix credo --strict     # Lint
mix compile --warnings-as-errors  # Zero warnings
mix test               # Run tests
mix dialyzer           # Type checking (slow on first run)
mix deps.audit         # Unused locks, retired packages and security advisories
```

CI runs `mix hex.audit`, which fails on any locked dependency with a published security
advisory. A new advisory can turn CI red with no code change. To find the fixed version,
query OSV (`curl -s https://api.osv.dev/v1/query -X POST -d
'{"package":{"name":"<dep>","ecosystem":"Hex"}}'`) and read each entry's
`affected[].ranges[].events[].fixed`, then bump the dependency, and any dependency whose
version constraint blocks it, to at least that version.

## Publication

The dispatch-only `publish.yml` runs from the default branch and publishes new versions
of existing Hex.pm packages only. It refuses a package name the registry has never had;
a first publication is the owner's decision.

The `build` job builds and inspects the package and docs without a publishing environment.
It passes the archives, checksums and upload plan to `upload`, the only job in environment
`publish`. That job runs no project code, verifies the checksums, and exchanges GitHub OIDC
for a 15-minute Hex workload token scoped to this public package. It uploads with the pinned
Hex client and revokes the token even after failure. No stored Hex key is used. Only this job
has `id-token: write`; every job retains the publisher actor restrictions.

A second dispatch on the same commit finishes a staged or partial publication: an existing
package must match the inspected bytes, served docs are kept, and nothing is replaced.
The `read-back` job runs after a successful upload or when nothing needs uploading. It checks
the served package and docs, including the docs' `release.json` commit, and assembles the
existing `release-assets` artifact without a publishing environment or token.

## Reporting Issues

Use the [issue templates](https://github.com/baselabs/ash_age/issues/new/choose) on GitHub. Include your Elixir, OTP, and Apache AGE versions.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
