defmodule AshAge.Integration.MultitenancyContextTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL

  defmodule Doc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s3_ctx_base)
      repo(AshAge.TestRepo)
      label(:Doc)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
    end

    actions do
      default_accept([:title])
      defaults([:read, :create, :update, :destroy])
    end
  end

  @tenant_a "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @tenant_b "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

  # Graph teardown is registered at the module (`setup_all`) scope, NOT in the
  # per-test `setup`. `AshAge.DataCase`'s per-test `setup` opens a shared Sandbox
  # owner transaction and only rolls it back (via `stop_owner`) in its own
  # per-test `on_exit`. `drop_graph` needs an ACCESS EXCLUSIVE lock on the graph's
  # `ag_catalog` tables, which the boxed cypher reads in the test leave held by
  # that still-open owner transaction. A per-test `on_exit` drop is registered
  # AFTER DataCase's `stop_owner` (LIFO ⇒ it runs BEFORE the rollback), so it
  # would block on the lock and time out (~15s) leaving the graphs orphaned.
  # A `setup_all` `on_exit` runs after every per-test owner transaction is gone,
  # so the drop takes the lock immediately and cleans the DB. Graph DDL is not
  # rolled back by the Sandbox, so the unboxed drop is what cleans up.
  setup_all do
    graph_a = AshAge.tenant_graph(Doc, @tenant_a)
    graph_b = AshAge.tenant_graph(Doc, @tenant_b)

    on_exit(fn ->
      SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{graph_a}', true)", [])
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{graph_b}', true)", [])
      end)
    end)

    :ok
  end

  setup do
    graph_a = AshAge.tenant_graph(Doc, @tenant_a)
    graph_b = AshAge.tenant_graph(Doc, @tenant_b)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      # provision_tenant is idempotent — safe to call, and we call twice to prove it.
      :ok = AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_a, vlabels: ["Doc"])
      :ok = AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_a, vlabels: ["Doc"])
      :ok = AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_b, vlabels: ["Doc"])
    end)

    :ok
  end

  test "context tenancy physically isolates create/read/update/destroy across graphs" do
    {:ok, a} =
      Doc |> Ash.Changeset.for_create(:create, %{title: "A"}, tenant: @tenant_a) |> Ash.create()

    {:ok, _b} =
      Doc |> Ash.Changeset.for_create(:create, %{title: "B"}, tenant: @tenant_b) |> Ash.create()

    # Read isolation: each tenant's graph holds only its own vertex.
    assert {:ok, [only_a]} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @tenant_a)
    assert only_a.title == "A"
    assert {:ok, [only_b]} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @tenant_b)
    assert only_b.title == "B"

    # Update isolation.
    {:ok, a2} =
      a |> Ash.Changeset.for_update(:update, %{title: "A2"}, tenant: @tenant_a) |> Ash.update()

    assert a2.title == "A2"

    # Destroy isolation: destroying in A leaves B intact.
    :ok = a2 |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: @tenant_a) |> Ash.destroy()
    assert {:ok, []} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @tenant_a)
    assert {:ok, [_]} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @tenant_b)
  end
end
