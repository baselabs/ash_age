defmodule AshAge.Integration.RlsDataLayerTest do
  @moduledoc """
  End-to-end: an rls_guc resource driven through Ash actions, with RLS enforced by
  the data layer's own with_rls (repo.transaction + set_config + run_query). Proves
  the COMPOSITION under the real (unboxed) topology and under a non-superuser role.
  The role is established in an outer TestRepo.transaction; Ash actions in the same
  process reuse that pinned connection, so the data layer's nested with_rls
  transaction sets the GUC on the SAME backend the SET LOCAL ROLE applies to.

  SCOPE / redundancy disclosure: for this `:attribute` rls_guc resource the
  read/update tenant-scoping is JOINTLY enforced by Ash's `:attribute` WHERE filter
  (`org_id == to_tenant`, baked into both the read and update cypher) AND RLS's
  USING — so this file does NOT prove RLS in isolation. RLS-in-isolation is proven
  in `rls_isolation_test.exs` (raw cypher, no `:attribute` layer), including its
  `with_tenant_rls/4` Case A. What this file genuinely adds beyond the isolation
  test: it proves the GUC actually gets set THROUGH the data layer's with_rls under
  a non-superuser role — otherwise RLS's blank-GUC guard would hide own-tenant rows
  too and the reads would come back empty — and that the composed stack (Ash actions
  + data-layer with_rls + :attribute barrier + RLS) fails closed end-to-end.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule Doc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_rls_e2e)
      repo(AshAge.TestRepo)
      label(:Doc)
      rls_guc("ash_age.tenant_id")
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, allow_nil?: false, public?: true)
      attribute(:body, :string, public?: true)
    end

    actions do
      default_accept([:body])
      defaults([:read, :create, :update, :destroy])
    end
  end

  @role "ash_age_rls_e2e_role"
  @t1 "11111111-1111-1111-1111-111111111111"
  @t2 "22222222-2222-2222-2222-222222222222"

  test "RLS resource: read is enforced through the data layer under a non-superuser role" do
    with_graph(
      "itest_rls_e2e",
      fn ->
        # 1. Composition (as superuser, before RLS): create + read work through with_rls.
        {:ok, a} =
          Doc |> Ash.Changeset.for_create(:create, %{body: "a"}, tenant: @t1) |> Ash.create()

        {:ok, _b} =
          Doc |> Ash.Changeset.for_create(:create, %{body: "b"}, tenant: @t2) |> Ash.create()

        assert {:ok, [only]} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @t1)
        assert only.body == "a"

        # 2. Enable RLS via the resource-derived helper (also covers enable_tenant_rls/2).
        :ok = AshAge.Migration.enable_tenant_rls(TestRepo, Doc)
        reset_role()
        exec(~s|CREATE ROLE #{@role} NOLOGIN|)
        exec(~s|GRANT USAGE ON SCHEMA ag_catalog, itest_rls_e2e TO #{@role}|)

        exec(
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ag_catalog TO #{@role}|
        )

        exec(
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA itest_rls_e2e TO #{@role}|
        )

        exec(~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA itest_rls_e2e TO #{@role}|)

        try do
          # 3. Enforcement through the data layer under the role: the GUC the data
          # layer sets (from tenant: @t1) scopes the RLS-enforced cypher read. The
          # reads run in their own role-pinned transaction; a returned `:ok` value
          # confirms the outer transaction committed cleanly (no poisoning).
          {:ok, :reads_ok} =
            TestRepo.transaction(fn ->
              exec(~s|SET LOCAL ROLE #{@role}|)
              assert {:ok, [only]} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @t1)
              assert only.body == "a"
              assert {:ok, [other]} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @t2)
              assert other.body == "b"
              :reads_ok
            end)

          # A fabricated cross-tenant update fails closed. The ENFORCER here is the
          # app-layer :attribute write barrier: Ash injects `org_id == @t2` into the
          # update cypher WHERE, which matches 0 rows for a t1 row (→ StaleRecord)
          # regardless of RLS. RLS's USING would also hide the row, but is redundant
          # for this :attribute source, and RLS's write-side WITH CHECK is bypassed by
          # AGE cypher() anyway (documented). It runs in its OWN role-pinned
          # transaction: Ash core wraps the update action in a transaction and calls
          # rollback on the failed action, so the enclosing TestRepo.transaction
          # returns {:error, changeset}. Match on THAT — the StaleRecord fail-closed
          # is the security proof of the :attribute barrier (unchanged), and isolating
          # it in its own transaction keeps that rollback from poisoning the reads.
          txn_result =
            TestRepo.transaction(fn ->
              exec(~s|SET LOCAL ROLE #{@role}|)

              struct(Doc, id: a.id, org_id: @t2, body: "a")
              |> Ash.Changeset.for_update(:update, %{body: "HACKED"}, tenant: @t2)
              |> Ash.update()
            end)

          assert {:error, err} = txn_result

          assert Enum.any?(
                   List.wrap(Map.get(err, :errors, [err])),
                   &match?(%Ash.Error.Changes.StaleRecord{}, &1)
                 )
        after
          reset_role()
        end
      end,
      vlabels: ["Doc"]
    )
  end

  defp reset_role do
    exec(
      ~s|DO $$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@role}') THEN EXECUTE 'DROP OWNED BY #{@role}'; EXECUTE 'DROP ROLE #{@role}'; END IF; END $$|
    )
  end
end
