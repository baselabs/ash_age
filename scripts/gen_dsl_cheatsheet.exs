# Regenerates the DSL reference extra from the AshAge.DataLayer extension schema.
#
#     mix run scripts/gen_dsl_cheatsheet.exs
#
# This avoids depending on `igniter`, which `mix spark.cheat_sheets` requires.
path = "documentation/dsls/DSL-AshAge.DataLayer.md"
File.mkdir_p!(Path.dirname(path))
File.write!(path, Spark.CheatSheet.cheat_sheet(AshAge.DataLayer))
IO.puts("Wrote #{path}")
