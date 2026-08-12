defmodule AshAge.Integration.DestroyQueryTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  # Plain resource: bulk destroy by query (one DETACH DELETE over a translated
  # filter, not N per-record destroys). can?(:destroy_query) gates the path; when
  # false Ash falls back to per-record destroy/2 (correct but slower). This test
  # proves the destroy_query path is CORRECT: the translated WHERE deletes exactly
  # the matched rows and the WHERE carries the tenant scope (F5).
  defmodule Thing do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_destroy_query
      repo AshAge.TestRepo
      label :Thing
    end

    attributes do
      uuid_primary_key :id
      attribute :status, :string, allow_nil?: false, public?: true
      attribute :value, :integer, public?: true
    end

    actions do
      default_accept [:status, :value]
      defaults [:read, :destroy]

      create :create do
        accept [:status, :value]
      end
    end
  end

  # :attribute multitenant resource for the F5 cross-tenant tripwire: a destroy_query
  # under tenant A must delete ONLY A's matched rows; tenant B's rows must SURVIVE
  # (re-read B and assert). The barrier is the translated WHERE carrying the tenant
  # predicate Ash attaches to the bulk-action query.
  defmodule TenantThing do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    age do
      graph :itest_destroy_query_tenant
      repo AshAge.TestRepo
      label :TenantThing
    end

    attributes do
      attribute :org_id, :string, primary_key?: true, allow_nil?: false, public?: true
      uuid_primary_key :id
      attribute :status, :string, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:status]
      defaults [:read, :destroy]

      create :create do
        accept [:status]
      end
    end
  end

  describe "bulk destroy by query" do
    test "deletes only the matched rows; unmatched survive" do
      with_graph(:itest_destroy_query, fn ->
        {:ok, _} = create(Thing, %{status: "active", value: 1})
        {:ok, _} = create(Thing, %{status: "active", value: 2})
        {:ok, _} = create(Thing, %{status: "archived", value: 3})

        query = Thing |> Ash.Query.for_read(:read) |> Ash.Query.filter(status == "active")
        assert %Ash.BulkResult{status: :success} = Ash.bulk_destroy!(query, :destroy, %{})

        remaining = Ash.read!(Thing)
        assert length(remaining) == 1
        assert hd(remaining).status == "archived"
      end)
    end

    test "0-match returns success (not an error)" do
      with_graph(:itest_destroy_query, fn ->
        {:ok, _} = create(Thing, %{status: "active", value: 1})

        query = Thing |> Ash.Query.for_read(:read) |> Ash.Query.filter(status == "missing")
        assert %Ash.BulkResult{status: :success} = Ash.bulk_destroy!(query, :destroy, %{})

        # Nothing deleted.
        assert length(Ash.read!(Thing)) == 1
      end)
    end

    test "honors a query limit — deletes exactly LIMIT rows, not the full set" do
      # Ash does NOT slice the query above the data layer for destroy_query
      # (bulk.ex:622-723), so a user-supplied limit must bound the deletion HERE or
      # it over-deletes. Seed 5, limit(2) → exactly 2 deleted, 3 survive.
      with_graph(:itest_destroy_query, fn ->
        for _ <- 1..5, do: {:ok, _} = create(Thing, %{status: "active", value: 1})

        query =
          Thing
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(status == "active")
          |> Ash.Query.limit(2)

        assert %Ash.BulkResult{status: :success} = Ash.bulk_destroy!(query, :destroy, %{})

        assert length(Ash.read!(Thing)) == 3
      end)
    end

    test "return_records? returns the destroyed records (read-then-delete path)" do
      # Cypher can't RETURN deleted nodes, so return_records? reads the matched set
      # first then deletes. This exercises that two-statement path.
      with_graph(:itest_destroy_query, fn ->
        {:ok, _} = create(Thing, %{status: "active", value: 1})
        {:ok, _} = create(Thing, %{status: "active", value: 2})
        {:ok, _} = create(Thing, %{status: "archived", value: 3})

        query = Thing |> Ash.Query.for_read(:read) |> Ash.Query.filter(status == "active")

        assert %Ash.BulkResult{status: :success, records: records} =
                 Ash.bulk_destroy!(query, :destroy, %{}, return_records?: true)

        assert length(records) == 2
        assert Enum.all?(records, &(&1.status == "active"))
        # Only the archived row survives.
        assert length(Ash.read!(Thing)) == 1
      end)
    end
  end

  describe "cross-tenant isolation (F5 tripwire)" do
    test "destroy_query under tenant A deletes only A's rows; B's rows survive" do
      with_graph(:itest_destroy_query_tenant, fn ->
        org_a = "org-a"
        org_b = "org-b"

        # Both tenants have an "active" row with the SAME status.
        {:ok, _} = create(TenantThing, %{status: "active"}, org_a)
        {:ok, a2} = create(TenantThing, %{status: "archived"}, org_a)
        {:ok, b_active} = create(TenantThing, %{status: "active"}, org_b)
        {:ok, b_archived} = create(TenantThing, %{status: "archived"}, org_b)

        # Tenant A destroys all its "active" rows. A buggy unscoped WHERE would
        # delete B's "active" row too (same status, no tenant predicate).
        #
        # The tenant rides the QUERY (Ash.Query.set_tenant/2) — Ash's documented
        # contract for bulk ops: the atomic destroy dispatch (do_atomic_destroy →
        # handle_multitenancy) reads `query.tenant`, which the stream/per-record
        # path also tolerates via opts-tenant but the atomic path does not. With
        # :update_query+:expr_error advertised (this slice), bulk_destroy routes
        # through destroy_query/4, so the tenant MUST be on the query. This is
        # also the first time this tripwire actually exercises destroy_query/4 —
        # pre-slice it silently used the per-record stream fallback.
        query =
          TenantThing
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(status == "active")
          |> Ash.Query.set_tenant(org_a)

        assert %Ash.BulkResult{status: :success} =
                 Ash.bulk_destroy!(query, :destroy, %{}, tenant: org_a)

        # A: only "archived" survives (compare data fields, not the whole struct —
        # a freshly-loaded record carries :loaded meta vs the seed's :built).
        assert {:ok, [a_after]} =
                 TenantThing |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_a)

        assert a_after.id == a2.id
        assert a_after.status == "archived"

        # B: BOTH rows survive (re-read — the binding F5 assertion).
        assert {:ok, b_remaining} =
                 TenantThing |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_b)

        assert length(b_remaining) == 2
        assert b_active.id in Enum.map(b_remaining, & &1.id)
        assert b_archived.id in Enum.map(b_remaining, & &1.id)
      end)
    end
  end

  defp create(resource, attrs, tenant \\ nil) do
    changeset = resource |> Ash.Changeset.for_create(:create, attrs)
    if tenant, do: Ash.create(changeset, tenant: tenant), else: Ash.create(changeset)
  end
end
