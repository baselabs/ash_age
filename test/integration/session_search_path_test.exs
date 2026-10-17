defmodule AshAge.Integration.SessionSearchPathTest do
  @moduledoc """
  Pins the search_path ORDER on live pool connections (AGENTS.md rule 4):
  `public, ag_catalog, "$user"` — public first so `ag_catalog.schema_migrations`
  never shadows Ecto's `public.schema_migrations`. The order is set per
  connection by `AshAge.Session.setup/1` (config/test.exs wires it as the
  repo's `after_connect`), so querying a real connection verifies the wiring
  end to end. The unit session test only asserts exports; this asserts the
  live, ordered value.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.Session
  alias AshAge.TestRepo
  alias Ecto.Adapters.SQL

  test "pool connections carry search_path with public FIRST, ag_catalog second" do
    assert {:ok, %{rows: [[path]]}} =
             SQL.query(TestRepo, "SHOW search_path", [])

    normalized = path |> String.replace(" ", "")
    assert normalized =~ ~s(public,ag_catalog,"$user")
  end
end
