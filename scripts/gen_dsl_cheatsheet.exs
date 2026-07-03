# Regenerates the DSL reference extra from the AshAge.DataLayer extension schema.
#
#     mix run scripts/gen_dsl_cheatsheet.exs
#
# The output is deterministic (it reads the static Spark schema), so a CI check
# can diff the committed file against a fresh run. This avoids depending on
# `igniter` (which `mix spark.cheat_sheets` requires) just to render docs.
path = "documentation/dsls/DSL-AshAge.DataLayer.md"
File.mkdir_p!(Path.dirname(path))
File.write!(path, Spark.CheatSheet.cheat_sheet(AshAge.DataLayer))
IO.puts("Wrote #{path}")
