defmodule AshAge.Integration.UpsertTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  # Non-multitenant resource with a declared `:email` identity. AGE enforces no
  # PK uniqueness and MERGE is banned (AGENTS.md rule 2), so upsert uses the
  # two-statement MATCH-then-CREATE/SET path. The identity NAME (:email) is what
  # Ash passes; the match field list comes from the identity struct.
  defmodule User do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_upsert
      repo AshAge.TestRepo
      label :User
    end

    attributes do
      uuid_primary_key :id
      attribute :email, :string, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    identities do
      identity :email, [:email]
    end

    actions do
      default_accept [:email, :name]
      defaults [:read]

      create :create do
        accept [:email, :name]
        upsert? true
        upsert_identity :email
      end

      # A plain create (no upsert) for seeding the "pre-existing row" cases.
      create :seed do
        accept [:email, :name]
      end
    end
  end

  # :attribute multitenant resource for the cross-tenant-row-theft tripwire (C2/F1/F2):
  # the existence MATCH must AND the tenant predicate derived from the FORCE-SET
  # multitenancy attribute (not changeset.filter, which is nil on the create path),
  # so a tenant-B upsert of an email that exists in tenant A CREATES in B and
  # leaves A's row untouched.
  defmodule TenantUser do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    age do
      graph :itest_upsert_tenant
      repo AshAge.TestRepo
      label :TenantUser
    end

    attributes do
      attribute :org_id, :string, primary_key?: true, allow_nil?: false, public?: true
      uuid_primary_key :id
      attribute :email, :string, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    identities do
      identity :email, [:email]
    end

    actions do
      default_accept [:email, :name]
      defaults [:read]

      create :create do
        accept [:email, :name]
        upsert? true
        upsert_identity :email
      end

      create :seed do
        accept [:email, :name]
      end
    end
  end

  describe "basic upsert (non-multitenant)" do
    test "upsert creates when the identity is absent" do
      with_graph(:itest_upsert, fn ->
        assert {:ok, %User{id: id, email: "a@x"}} =
                 User
                 |> Ash.Changeset.for_create(:create, %{email: "a@x", name: "A"})
                 |> Ash.create(upsert?: true, upsert_identity: :email)

        assert [^id] = ids(User)
      end)
    end

    test "upsert updates when the identity is present (same id, new attrs)" do
      with_graph(:itest_upsert, fn ->
        {:ok, %User{id: id}} =
          User
          |> Ash.Changeset.for_create(:create, %{email: "a@x", name: "A"})
          |> Ash.create(upsert?: true, upsert_identity: :email)

        assert {:ok, %User{id: ^id, name: "A2"}} =
                 User
                 |> Ash.Changeset.for_create(:create, %{email: "a@x", name: "A2"})
                 |> Ash.create(upsert?: true, upsert_identity: :email)

        # Exactly one row — no duplicate vertex.
        assert [^id] = ids(User)
      end)
    end

    test "upsert is idempotent across repeated calls" do
      with_graph(:itest_upsert, fn ->
        for _ <- 1..4 do
          {:ok, %User{}} =
            User
            |> Ash.Changeset.for_create(:create, %{email: "a@x", name: "A"})
            |> Ash.create(upsert?: true, upsert_identity: :email)
        end

        assert length(ids(User)) == 1
      end)
    end
  end

  describe "cross-tenant isolation (C2/F1/F2 binding tripwire)" do
    test "tenant-B upsert of an email that exists in tenant A CREATES in B, leaves A untouched" do
      with_graph(:itest_upsert_tenant, fn ->
        org_a = "org-a"
        org_b = "org-b"

        # Tenant A owns email a@x.
        {:ok, %TenantUser{id: a_id} = a_row} =
          TenantUser
          |> Ash.Changeset.for_create(:seed, %{email: "a@x", name: "from-A"})
          |> Ash.create(tenant: org_a)

        # Tenant B upserts the SAME email. A correct existence MATCH (identity
        # AND org_id=B) excludes A's row → CREATE in B. A buggy unscoped match
        # (identity only) would STEAL A's row (rewrite org_id B→A's row).
        assert {:ok, %TenantUser{id: b_id, org_id: ^org_b}} =
                 TenantUser
                 |> Ash.Changeset.for_create(:create, %{email: "a@x", name: "from-B"})
                 |> Ash.create(tenant: org_b)

        # Binding assertion: A's row is UNCHANGED. Compare data fields (not the
        # whole struct — a freshly-loaded record carries :loaded meta, the seed
        # carried :built, so struct equality is too strict). A stolen row would
        # show a changed id/name/org_id here.
        refute a_id == b_id

        assert {:ok, [a_after]} =
                 TenantUser |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_a)

        assert a_after.id == a_row.id
        assert a_after.name == "from-A"
        assert a_after.org_id == org_a
      end)
    end

    test "tenant-A upsert UPDATE branch leaves a cross-tenant duplicate (B's row) untouched" do
      # The cross-tenant-row-theft test above exercises only the CREATE branch (B's
      # existence check returns 0). This tripwire forces the UPDATE branch with a
      # cross-tenant duplicate present: both tenants hold email a@x. Without the
      # tenant predicate in the update-branch WHERE, the SET-bearing MATCH would hit
      # BOTH rows (identity-only) and corrupt B's row — the S3 regression. The
      # duplicate is RAW-SEEDED (cypher_query) because Ash's GLOBAL email identity
      # would otherwise block a same-email create — modeling the documented race /
      # external write that produces the duplicate.
      with_graph(:itest_upsert_tenant, fn ->
        org_a = "org-a"
        org_b = "org-b"
        b_id = Ash.UUID.generate()

        {:ok, %TenantUser{id: a_id}} =
          TenantUser
          |> Ash.Changeset.for_create(:seed, %{email: "a@x", name: "A-orig"})
          |> Ash.create(tenant: org_a)

        # Raw-seed B's same-email duplicate, bypassing Ash's identity check.
        assert {:ok, _} =
                 cypher_query(
                   :itest_upsert_tenant,
                   "CREATE (n:TenantUser) SET n.org_id = $org_id, n.id = $id, " <>
                     "n.email = $email, n.name = $name RETURN n",
                   %{"org_id" => org_b, "id" => b_id, "email" => "a@x", "name" => "B-orig"}
                 )

        # Tenant A upserts — existence (email AND org_id=A) sees only A's row → c=1
        # → UPDATE branch. The update-branch WHERE must AND org_id=A so the SET
        # touches ONLY A's row, not B's same-email duplicate.
        assert {:ok, %TenantUser{id: ^a_id}} =
                 TenantUser
                 |> Ash.Changeset.for_create(:create, %{email: "a@x", name: "A-new"})
                 |> Ash.create(tenant: org_a)

        # A's row updated in place.
        assert {:ok, [a_after]} =
                 TenantUser |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_a)

        assert a_after.id == a_id
        assert a_after.name == "A-new"

        # B's row UNCHANGED — the binding assertion. A buggy identity-only WHERE
        # would have SET B's name to "A-new". Re-read under B and assert the
        # original name + org + id survive.
        assert {:ok, [b_after]} =
                 TenantUser |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_b)

        assert b_after.id == b_id
        assert b_after.name == "B-orig"
        assert b_after.org_id == org_b
      end)
    end
  end

  # :attribute multitenant resource with an `all_tenants?: true` identity. Ash
  # (create.ex:305) does NOT prepend the mt attr to identity_fields for
  # all_tenants? identities — the identity is INTENTIONALLY global. A correct
  # upsert MATCHES across tenants (global); a layer that wrongly re-adds a tenant
  # predicate would force a per-tenant CREATE instead (a duplicate — the bug the
  # tenant_pred simplification removed).
  defmodule GlobalUser do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    age do
      graph :itest_upsert_global
      repo AshAge.TestRepo
      label :GlobalUser
    end

    attributes do
      attribute :org_id, :string, primary_key?: true, allow_nil?: false, public?: true
      uuid_primary_key :id
      attribute :email, :string, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    identities do
      identity(:email, [:email], all_tenants?: true)
    end

    actions do
      default_accept [:email, :name]
      defaults [:read]

      create :create do
        accept [:email, :name]
        upsert? true
        upsert_identity :email
      end

      create :seed do
        accept [:email, :name]
      end
    end
  end

  describe "all_tenants? identity (global upsert — the simplification proof)" do
    test "a global-identity upsert MATCHES across tenants (no per-tenant duplicate)" do
      with_graph(:itest_upsert_global, fn ->
        org_a = "org-a"
        org_b = "org-b"

        # Tenant A owns the global email.
        {:ok, %GlobalUser{id: a_id}} =
          GlobalUser
          |> Ash.Changeset.for_create(:seed, %{email: "g@x", name: "A"})
          |> Ash.create(tenant: org_a)

        # Tenant B upserts the SAME global email. A correct all_tenants? upsert
        # MATCHES A's row (identity_fields = [:email], no org_id) and updates it;
        # a layer that wrongly re-added a tenant predicate would CREATE in B
        # instead (a duplicate).
        assert {:ok, %GlobalUser{id: ^a_id}} =
                 GlobalUser
                 |> Ash.Changeset.for_create(:create, %{email: "g@x", name: "B"})
                 |> Ash.create(tenant: org_b)

        # The global row was UPDATED in place (same id), not duplicated. org_id is
        # a PK so it is excluded from the SET — the row stays under org-a with the
        # new name. Reading under org-b yields nothing (no duplicate created).
        assert {:ok, [a_after]} =
                 GlobalUser |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_a)

        assert a_after.id == a_id
        assert a_after.name == "B"

        assert {:ok, []} = GlobalUser |> Ash.Query.for_read(:read) |> Ash.read(tenant: org_b)
      end)
    end
  end

  defp ids(resource) do
    resource |> Ash.read!() |> Enum.map(& &1.id)
  end
end
