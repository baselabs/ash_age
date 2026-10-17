# Testing ash_age resources

How to test resources backed by ash_age — and how ash_age tests itself, which
is the same problem one level down.

## The two lanes

| Lane | Command | Needs a database? |
|---|---|---|
| Unit | `mix test.unit` | No |
| Integration | `mix test.integration` | Yes — `AGE_DATABASE_URL` set |

`mix test` runs both when `AGE_DATABASE_URL` points at a live Apache AGE
server, and only the unit lane when it is unset. Use the aliases rather than
managing the variable yourself: an empty-string `AGE_DATABASE_URL` is truthy
and would run the integration lane against nothing.

The quickest local server is the repo's compose file (see the README's
["A database to develop against"](../README.md)); CI pins the same image by
digest.

## What makes AGE tests different from Postgres tests

Two properties of AGE shape everything else:

1. **Graph DDL is not transactional.** `create_graph` cannot be rolled back by
   the SQL Sandbox, so test isolation cannot come from transaction rollback.
   It comes from a **unique graph per test** plus `drop_graph` afterward.
2. **AGE does not support concurrent transactions against the same graph.**
   Integration tests must be `async: false`.

## The pattern

```elixir
defmodule MyApp.DocTest do
  # Every AGE integration test: async: false, @moduletag :integration
  use ExUnit.Case, async: false
  @moduletag :integration

  # If you use the SQL Sandbox (you likely already do for your Repo):
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "creates and reads back" do
    # Create the graph on an UNBOXED connection (DDL), run the body, drop it.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(MyApp.Repo, fn ->
      exec("SELECT ag_catalog.create_graph('my_app_doc_test')")
      exec("SELECT ag_catalog.create_vlabel('my_app_doc_test', 'Doc')")

      try do
        {:ok, doc} = MyApp.Doc |> Ash.Changeset.for_create(:create, %{...}) |> Ash.create()
        assert [%{}] = Ash.read!(MyApp.Doc)
      after
        exec("SELECT ag_catalog.drop_graph('my_app_doc_test', true)")
      end
    end)
  end

  defp exec(sql), do: Ecto.Adapters.SQL.query!(MyApp.Repo, sql, [])
end
```

The shape to internalize: **wrap the whole test body** (create → assertions →
drop), don't create the graph in `setup` — a helper that drops on exit after
`setup` returns will have already dropped it before the test runs.

Labels matter too: AGE creates a vertex label implicitly on first `CREATE`,
but provisioning labels explicitly (as above) keeps `drop_graph` behavior
predictable and matches what `AshAge.Migration.create_vertex_label/2` does in
your real migrations.

## Multitenancy under test

- `:context` (graph-per-tenant) gives physical isolation for free — provision
  the tenant graph with `AshAge.Migration.provision_tenant/3` in the test.
- `:attribute` tenancy is a WHERE predicate: the strongest tests fabricate an
  attacker record in a DIFFERENT tenant (seeded first), then assert the
  cross-tenant read/update/destroy fails closed — not merely that the right
  tenant's rows come back.

## What to assert beyond happy paths

The failure modes worth pinning for a data layer:

- **Fail-closed errors are value-free** — an unsupported filter or a DB
  failure surfaces operator/SQLSTATE-shaped errors, never row values.
- **Scoped mutations return `StaleRecord`** on a 0-row tenant/policy match
  (the Ash contract for record-based updates/destroys).
- **Parameterization**: if you capture executed SQL (Ecto's
  `[:my_app, :repo, :query]` telemetry carries `query` and `params`), user
  values appear only in the params, never in the SQL body.

## Reference

ash_age's own suite (`test/` in the repo) uses exactly this pattern via
`AshAge.DataCase.with_graph/3` — reading it is the fastest way to see the
conventions applied, including RLS role-switching and cross-tenant tripwires.
