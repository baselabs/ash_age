# Contributing to ash_age

Thank you for your interest in contributing to `ash_age`!

## Setting Up Development

```bash
git clone https://github.com/baselabs/ash_age.git
cd ash_age
mix deps.get
mix test
```

## Running Tests

```bash
mix test                         # Run all tests
mix test test/path/to/test.exs   # Run specific test file
mix test --failed                  # Re-run failed tests
```

## Code Style

- Follow the existing code style
- Use `mix format` before committing
- Run `mix credo --strict` and fix issues

## Submitting Changes

1. Fork the repository
2. Create a branch for your feature
3. Make your changes with clear commit messages
4. Push to your fork
5. Open a Pull Request

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
