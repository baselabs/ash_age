defmodule AshAge.Integration.RlsTraverseTest do
  @moduledoc """
  Case B — live proof that traverse's `with_rls` routing RLS-scopes a live
  traversal (deferred from Task 6). The SOURCE is an `rls_guc` `:attribute`
  resource with a manual `Traverse` relationship; traverse routes its read through
  `DataLayer.with_rls(source, context.tenant, repo, ...)`, which opens
  `repo.transaction` and `set_config`s the GUC on that pinned connection.

  To exercise RLS as the DB-enforced barrier the traversal runs under a throwaway
  non-superuser role. The role is set in an outer `TestRepo.transaction`; the
  Ash load in the same process reuses that pinned connection, so traverse's nested
  `with_rls` transaction sets the GUC on the SAME backend the SET LOCAL ROLE
  applies to.

  SCOPE / redundancy finding (verified live via a temporary `BYPASSRLS` probe):
  for an `:attribute` `rls_guc` source the two scoping layers are REDUNDANT and
  cannot be independently isolated by a black-box traversal. Traverse's per-hop
  `:attribute` UNION scope (`b.tenant_id = $tenant`) and the RLS policy
  (`extract(properties,'tenant_id') = current_setting(guc)`) read the SAME property
  against the SAME tenant value, so either alone hides the cross-tenant destination
  — a `BYPASSRLS` role still returns `["b"]`. This test therefore proves the
  COMPOSED live fail-closed guarantee (traverse under RLS+role never surfaces a
  cross-tenant destination) rather than the RLS layer in isolation. The RLS-routing
  seam's own RED-capability is carried DB-free by the `wrap_traverse_error/1` unit
  tests (the error-normalization boundary the `with_rls` wrap adds), per the scope
  note in `test/ash_age/manual_relationships/traverse_test.exs`.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule TNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_rls_traverse)
      repo(AshAge.TestRepo)
      label(:TNode)
      rls_guc("ash_age.tenant_id")
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tenant_id, :uuid, allow_nil?: false, public?: true)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :reachable, __MODULE__ do
        public?(true)

        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 3, min_depth: 1}
        )
      end
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  @role "ash_age_rls_traverse_role"
  @t1 "11111111-1111-1111-1111-111111111111"
  @t2 "22222222-2222-2222-2222-222222222222"

  test "traverse routes through with_rls: in-tenant destinations reached, cross-tenant RLS-hidden" do
    with_graph(
      "itest_rls_traverse",
      fn ->
        {:ok, a} = create(TNode, %{name: "a"}, @t1)
        {:ok, b} = create(TNode, %{name: "b"}, @t1)
        {:ok, x} = create(TNode, %{name: "x"}, @t2)

        # a(t1) -> b(t1): in-tenant edge.  a(t1) -> x(t2): OUT-OF-BAND cross-tenant edge.
        link(a.id, b.id)
        link(a.id, x.id)

        # Enable RLS via the resource-derived helper (also covers enable_tenant_rls/2).
        :ok = AshAge.Migration.enable_tenant_rls(TestRepo, TNode)
        reset_role()
        exec(~s|CREATE ROLE #{@role} NOLOGIN|)
        exec(~s|GRANT USAGE ON SCHEMA ag_catalog, itest_rls_traverse TO #{@role}|)

        exec(
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ag_catalog TO #{@role}|
        )

        exec(
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA itest_rls_traverse TO #{@role}|
        )

        exec(~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA itest_rls_traverse TO #{@role}|)

        try do
          {:ok, names} =
            TestRepo.transaction(fn ->
              exec(~s|SET LOCAL ROLE #{@role}|)
              {:ok, [loaded]} = Ash.load([a], :reachable, tenant: @t1)
              loaded.reachable |> Enum.map(& &1.name) |> Enum.sort()
            end)

          # b (in-tenant) reached — positive control that the traversal runs under
          # the role; x (cross-tenant) never surfaces — fail-closed under RLS+role.
          assert names == ["b"]
        after
          reset_role()
        end
      end,
      vlabels: ["TNode"],
      elabels: ["LINK"]
    )
  end

  defp create(resource, attrs, tenant) do
    resource |> Ash.Changeset.for_create(:create, attrs, tenant: tenant) |> Ash.create()
  end

  defp link(from_id, to_id) do
    {:ok, _} =
      cypher_query(
        "itest_rls_traverse",
        "MATCH (x:TNode {id: $from}), (y:TNode {id: $to}) CREATE (x)-[:LINK]->(y) RETURN 1",
        %{"from" => from_id, "to" => to_id}
      )
  end

  defp reset_role do
    exec(
      ~s|DO $$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@role}') THEN EXECUTE 'DROP OWNED BY #{@role}'; EXECUTE 'DROP ROLE #{@role}'; END IF; END $$|
    )
  end
end
