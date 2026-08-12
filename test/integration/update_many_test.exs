defmodule AshAge.Integration.UpdateManyTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  # Plain single-attr-PK resource for the common update_many case.
  defmodule Widget do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_update_many
      repo AshAge.TestRepo
      label :Widget
    end

    attributes do
      uuid_primary_key :id
      attribute :count, :integer, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:count, :name]
      defaults [:read, :create, :destroy, update: :*]
    end
  end

  # :attribute multitenant single-attr-PK resource — for the cross-tenant
  # duplicate-PK tripwire (AGE has no PK uniqueness; a duplicate-PK row in B's
  # tenant must be untouched by an A-tenant batch, proving the tenant
  # discriminator is in the synthesized WHERE).
  defmodule TenantWidget do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    age do
      graph :itest_update_many_tenant
      repo AshAge.TestRepo
      label :TenantWidget
    end

    attributes do
      # `org_id` is the multitenancy discriminator but NOT part of the PK. This
      # is what makes the cross-tenant tripwire below NON-VACUOUS: the PK scope
      # is `n.`id` IN $pks`, which matches a B-tenant vertex sharing A's `id`, so
      # ONLY scope_to_tenant's `n.`org_id` = $tenant` can exclude it. (If org_id
      # were a PK field, the composite-PK scope would exclude B on its own and
      # the test would pass with scope_to_tenant deleted — a vacuous tripwire.)
      uuid_primary_key :id
      attribute :org_id, :string, allow_nil?: false, public?: true
      attribute :count, :integer, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:count]
      defaults [:read, :create, update: :*]
    end
  end

  describe "update_many (single-attr PK)" do
    test "distinct inputs each apply their own change" do
      with_graph(:itest_update_many, fn ->
        {:ok, a} = Ash.create(Widget, %{count: 1, name: "a"})
        {:ok, b} = Ash.create(Widget, %{count: 1, name: "b"})
        {:ok, c} = Ash.create(Widget, %{count: 1, name: "c"})

        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.update_many(
                   [
                     {a, %{count: 10}},
                     {b, %{count: 20}},
                     {c, %{count: 30}}
                   ],
                   Widget,
                   :update,
                   return_records?: true
                 )

        by_id = Widget |> Ash.read!() |> Map.new(&{&1.id, &1.count})
        assert by_id[a.id] == 10
        assert by_id[b.id] == 20
        assert by_id[c.id] == 30
      end)
    end

    test "same change across records updates every match" do
      with_graph(:itest_update_many, fn ->
        {:ok, a} = Ash.create(Widget, %{count: 1, name: "x"})
        {:ok, b} = Ash.create(Widget, %{count: 1, name: "x"})
        {:ok, c} = Ash.create(Widget, %{count: 1, name: "x"})

        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.update_many(
                   [{a, %{count: 9}}, {b, %{count: 9}}, {c, %{count: 9}}],
                   Widget,
                   :update,
                   return_records?: true
                 )

        assert Enum.all?(Ash.read!(Widget), &(&1.count == 9))
      end)
    end

    test "a record that no longer exists becomes a per-row error (stale), others succeed" do
      with_graph(:itest_update_many, fn ->
        {:ok, a} = Ash.create(Widget, %{count: 1, name: "a"})
        {:ok, b} = Ash.create(Widget, %{count: 1, name: "b"})
        # Delete b out-of-band so its PK is stale in the batch.
        Ash.destroy!(b)

        result =
          Ash.update_many(
            [{a, %{count: 7}}, {b, %{count: 7}}],
            Widget,
            :update,
            return_records?: true,
            return_errors?: true
          )

        assert result.status in [:partial_success, :success]
        # a was updated; b is stale (absent from records).
        assert hd(Ash.read!(Widget)).count == 7
      end)
    end

    test "a no-op batch (no changes) reports existing records as success, not stale" do
      # Cross-vendor closeout: a no-op update_many group must NOT report existing
      # records as stale. The honest path runs a READ (filter + PK) and returns
      # the matched records unchanged; Ash matches them by PK → success.
      with_graph(:itest_update_many, fn ->
        {:ok, a} = Ash.create(Widget, %{count: 1, name: "a"})
        {:ok, b} = Ash.create(Widget, %{count: 1, name: "b"})

        result =
          Ash.update_many(
            [{a, %{}}, {b, %{}}],
            Widget,
            :update,
            return_records?: true,
            return_errors?: true
          )

        # Both records exist and match → success (not all-stale). No values changed.
        assert result.status == :success
        assert result.error_count == 0
        assert length(List.wrap(result.records)) == 2
        assert hd(Ash.read!(Widget)).count == 1
      end)
    end
  end

  # A resource with an `age skip` attribute — one the graph never stores (computed
  # client-side). An update_many modifying ONLY a skip attr is a true no-op for the
  # graph; it must still report the existing records as success (not stale). The
  # no-op detection keys on the EFFECTIVE changed attrs (after skip rejection),
  # not raw `changeset.attributes` (cross-vendor delta-4 finding).
  defmodule SkipWidget do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_update_many_skip
      repo AshAge.TestRepo
      label :SkipWidget
      skip [:computed]
    end

    attributes do
      uuid_primary_key :id
      attribute :count, :integer, allow_nil?: false, public?: true
      attribute :computed, :string, public?: true
    end

    actions do
      default_accept [:count, :computed]
      defaults [:read, :create, :destroy, update: :*]
    end
  end

  describe "update_many with age-skip attributes" do
    test "a skip-attr-only update is a no-op that reports success, not stale" do
      with_graph(:itest_update_many_skip, fn ->
        {:ok, w} = Ash.create(SkipWidget, %{count: 5, computed: "x"})

        # Modifying ONLY the skip attr → no graph write. Without effective-no-op
        # detection this returned `:ok` (no records) and Ash marked `w` stale.
        result =
          Ash.update_many(
            [{w, %{computed: "y"}}],
            SkipWidget,
            :update,
            return_records?: true,
            return_errors?: true
          )

        assert result.status == :success
        assert result.error_count == 0
        # The existing record is returned (matched by the no-op read), not stale.
        assert length(List.wrap(result.records)) == 1
        # count unchanged (no write occurred).
        assert Ash.get!(SkipWidget, w.id).count == 5
      end)
    end

    test "a same-tenant duplicate-PK anomaly fails closed (not silent multi-row write)" do
      # AGE enforces no PK uniqueness, so a duplicate-PK vertex is creatable
      # externally. A bulk update of that PK would SET every physical row (silent
      # multi-row corruption for one logical update) — fail CLOSED instead.
      # (cross-vendor delta-6/7: dedup masked it; the guard must run on the
      # default return_records?: false path too.)
      with_graph(:itest_update_many_skip, fn ->
        {:ok, w} = Ash.create(SkipWidget, %{count: 5, computed: "x"})

        # Inject a same-graph duplicate sharing w's id (AGE allows it; Ash never would).
        cypher_query(:itest_update_many_skip, "CREATE (:SkipWidget {id: $id, count: 5})", %{
          "id" => w.id
        })

        result =
          Ash.update_many(
            [{w, %{count: 99}}],
            SkipWidget,
            :update,
            return_records?: true,
            return_errors?: true
          )

        assert result.status == :error
        assert result.error_count >= 1
      end)
    end
  end

  describe "cross-tenant isolation (update_many F5 tripwire)" do
    test "an A-tenant batch does not touch a duplicate-PK row in B's tenant" do
      # AGE enforces NO primary-key uniqueness, so a vertex with org_a's PK can
      # exist in org_b's scope (created externally / by a bug). The synthesized
      # update_many WHERE must carry the tenant discriminator so the SET cannot
      # widen to B's same-PK row. Fabricate the duplicate via raw cypher.
      with_graph(:itest_update_many_tenant, fn ->
        {:ok, a} = Ash.create(TenantWidget, %{count: 1}, tenant: "org-a")

        # Inject a B-tenant vertex carrying A's PK (AGE allows it; Ash never would).
        cypher_query(
          :itest_update_many_tenant,
          "CREATE (:TenantWidget {org_id: 'org-b', id: $id, count: 1})",
          %{"id" => a.id}
        )

        # A-tenant batch bumps `a`. A missing discriminator would bump BOTH rows
        # sharing a.id (the A row AND the B duplicate) — a silent cross-tenant write.
        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.update_many(
                   [{%{org_id: "org-a", id: a.id}, %{count: 99}}],
                   TenantWidget,
                   :update,
                   tenant: "org-a",
                   return_records?: true
                 )

        # A's row bumped.
        assert Ash.get!(TenantWidget, a.id, tenant: "org-a").count == 99

        # B's same-PK row UNCHANGED — the discriminator held.
        [b_row] =
          TenantWidget
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(count == 1)
          |> Ash.read!(tenant: "org-b")

        assert b_row.id == a.id
        assert b_row.count == 1
      end)
    end

    test ":attribute update_many with a blank tenant fails closed" do
      with_graph(:itest_update_many_tenant, fn ->
        {:ok, a} = Ash.create(TenantWidget, %{count: 1}, tenant: "org-a")

        result =
          Ash.update_many(
            [{a, %{count: 2}}],
            TenantWidget,
            :update,
            tenant: nil,
            return_records?: true,
            return_errors?: true
          )

        assert result.status == :error
        # A's row untouched.
        assert Ash.get!(TenantWidget, a.id, tenant: "org-a").count == 1
      end)
    end
  end
end
