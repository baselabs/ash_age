import Config

config :ash_age, ecto_repos: [AshAge.TestRepo]

config :ash_age, AshAge.TestRepo,
  url:
    System.get_env("AGE_DATABASE_URL", "postgres://postgres:postgres@localhost:5432/ash_age_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  types: AshAge.TestPostgrexTypes,
  after_connect: {AshAge.Session, :setup, []}
