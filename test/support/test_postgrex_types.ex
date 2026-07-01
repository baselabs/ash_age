# `Postgrex.Types.define/3` itself defines the module named in its first argument
# (via `Module.create`), so it must be called at the top level — NOT wrapped in a
# `defmodule AshAge.TestPostgrexTypes`, which would collide with the module the macro
# is creating ("cannot define module ... currently being defined").
Postgrex.Types.define(
  AshAge.TestPostgrexTypes,
  [AshAge.Postgrex.AgtypeExtension] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
