# Used by `mix format`.
# `spark_locals_without_parens` lists ash_age's own `age do ... end` DSL calls so
# `mix format` leaves them unparenthesized, and `export:` shares them with consumers
# that add `:ash_age` to their `import_deps`. The list is maintained by hand: every
# new `age` option or `edge` key in `AshAge.DataLayer` is added here as `name: arity`,
# or consumers' `mix format` parenthesizes it.
spark_locals_without_parens = [
  graph: 1,
  repo: 1,
  label: 1,
  skip: 1,
  sensitive: 1,
  tenant_graph: 1,
  rls_guc: 1,
  edge: 1,
  direction: 1,
  destination: 1,
  properties: 1
]

[
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
