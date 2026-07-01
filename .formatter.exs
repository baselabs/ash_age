# Used by `mix format`.
# `spark_locals_without_parens` lists ash_age's own `age do ... end` DSL calls so
# `mix format` leaves them unparenthesized, and `export:` shares them with consumers
# that add `:ash_age` to their `import_deps`. Derived from the `age` section +
# `edge` entity schema in `AshAge.DataLayer` (equivalent to `mix spark.formatter
# --extensions AshAge.DataLayer`, which needs the optional :sourceror dep).
spark_locals_without_parens = [
  graph: 1,
  repo: 1,
  label: 1,
  skip: 1,
  edge: 1,
  direction: 1,
  destination: 1
]

[
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
