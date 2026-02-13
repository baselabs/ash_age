# Contributing to AshAge

Thank you for your interest in contributing to AshAge!

## Prerequisites

- **Elixir** 1.15+ and **Erlang/OTP** 26+
- **PostgreSQL** 14+ with [Apache AGE](https://age.apache.org/) extension installed
- Run `CREATE EXTENSION IF NOT EXISTS age;` in your test database

## Getting Started

```bash
git clone https://github.com/baselabs/ash_age.git
cd ash_age
mix deps.get
mix test
```

## Development Workflow

1. **Fork** the repository and create a feature branch from `master`
2. Make your changes with clear, descriptive commit messages
3. Ensure all checks pass before opening a PR:

```bash
mix format             # Format code
mix credo --strict     # Lint
mix compile --warnings-as-errors  # Zero warnings
mix test               # Run tests
mix dialyzer           # Type checking (slow on first run)
```

4. Update `CHANGELOG.md` under `[Unreleased]`
5. Open a Pull Request against `master`

## CI Pipeline

Every PR runs the following checks automatically:

| Check                              | What it does                         |
| ---------------------------------- | ------------------------------------ |
| `mix format --check-formatted`     | Enforces consistent formatting       |
| `mix credo --strict`               | Lints for code quality issues        |
| `mix compile --warnings-as-errors` | Zero tolerance for compiler warnings |
| `mix test`                         | Runs all tests against Apache AGE    |
| `mix dialyzer`                     | Static type analysis                 |

All checks must pass before a PR can be merged.

## Code Style

- Follow existing patterns in the codebase
- Use `mix format` — the `.formatter.exs` handles the config
- Keep functions small and well-documented
- Add `@moduledoc` and `@doc` to public modules and functions

## Reporting Issues

Use the [issue templates](https://github.com/baselabs/ash_age/issues/new/choose) on GitHub. Include your Elixir, OTP, and Apache AGE versions.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
