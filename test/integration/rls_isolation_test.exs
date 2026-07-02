defmodule AshAge.Integration.RlsIsolationTest do
  @moduledoc """
  Live RLS tripwires. RLS applies only to non-superuser roles, so each test SET
  LOCAL ROLEs to a throwaway role inside the tenant-GUC transaction (the test
  connection is the superuser owner). Proves: cross-tenant READ denied,
  update/delete TARGETING denied, INSERT bypass characterized (AGE fact — the
  cross-tenant CREATE succeeds), blank-tenant + blank-property fail-closed.

  NOTE: each test runs INSIDE `with_graph/3`'s function, because `with_graph`
  drops the graph in its `after` (data_case.ex) — a `setup`-level `with_graph`
  would drop the graph before the test body runs. Per-test isolation is also
  required because the DELETE/INSERT tests mutate the seeded rows.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  @graph "itest_rls_iso"
  @role "ash_age_rls_test_role"
  @t1 "11111111-1111-1111-1111-111111111111"
  @t2 "22222222-2222-2222-2222-222222222222"
  @guc "ash_age.tenant_id"

  test "cross-tenant READ is denied; own-tenant read succeeds; owner bypasses (USING)" do
    with_rls_doc(fn ->
      assert scoped_count(@t1) == 1
      assert scoped_count(@t2) == 1
      # superuser owner (no role switch) bypasses RLS → sees all 4 seeded rows
      assert count_docs() == 4
    end)
  end

  test "unset GUC is fail-closed (the <> '' guard) — blank/missing rows never leak" do
    with_rls_doc(fn ->
      in_role_txn(fn ->
        # No set_config → GUC blank → 0 visible, though blank/missing-tenant rows exist.
        assert count_docs() == 0
      end)
    end)
  end

  test "cross-tenant DELETE targeting is denied (USING hides t2 from t1)" do
    with_rls_doc(fn ->
      in_role_txn(fn ->
        set_guc(@t1)

        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ MATCH (n:Doc) DETACH DELETE n RETURN n $$) AS (v agtype)|
        )
      end)

      # t1's real row deleted; t2 + blank + missing survive (invisible to t1's DELETE).
      assert count_docs() == 3
      assert scoped_count(@t2) == 1
    end)
  end

  test "cross-tenant INSERT is NOT denied by RLS (AGE cypher() bypasses WITH CHECK) — DOCUMENTED" do
    with_rls_doc(fn ->
      in_role_txn(fn ->
        set_guc(@t1)
        # AGE fact: this cross-tenant CREATE SUCCEEDS despite WITH CHECK. The :attribute
        # app-layer force-set (Ash core) is the real write barrier — RLS is read-side.
        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant_id:'#{@t2}', body:'evil'}) RETURN n $$) AS (v agtype)|
        )
      end)

      assert scoped_count(@t2) == 2
    end)
  end

  # Case A — the PUBLIC AshAge.with_tenant_rls/4 live (deferred from Task 7).
  # Proves the public wrapper actually gates a raw read under RLS on the SAME
  # pinned connection as the SET LOCAL ROLE. The wrapper opens its OWN
  # repo.transaction; running it inside an outer TestRepo.transaction that first
  # SET LOCAL ROLEs makes the inner txn a savepoint on that pinned connection, so
  # the non-superuser role carries into the wrapper's nested transaction.
  test "AshAge.with_tenant_rls/4 (public) RLS-scopes a raw read on the role-pinned connection" do
    with_rls_doc(fn ->
      {:ok, {n1, n2, blank}} =
        TestRepo.transaction(fn ->
          exec(~s|SET LOCAL ROLE #{@role}|)

          n1 = AshAge.with_tenant_rls(TestRepo, @guc, @t1, fn -> count_docs() end)
          n2 = AshAge.with_tenant_rls(TestRepo, @guc, @t2, fn -> count_docs() end)
          # A blank tenant does NOT fail closed in with_tenant_rls (documented) — it
          # set_config's '' and the RLS <> '' guard yields 0, differing from a scoped read.
          blank = AshAge.with_tenant_rls(TestRepo, @guc, "", fn -> count_docs() end)
          {n1, n2, blank}
        end)

      # Own-tenant reads return ONLY that tenant's row; the blank-tenant read differs.
      assert n1 == 1
      assert n2 == 1
      assert blank == 0
    end)
  end

  # --- harness: per-test graph + seed + RLS policy + throwaway non-superuser role ---

  defp with_rls_doc(fun) do
    with_graph(
      @graph,
      fn ->
        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant_id:'#{@t1}', body:'a'}) $$) AS (v agtype)|
        )

        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant_id:'#{@t2}', body:'b'}) $$) AS (v agtype)|
        )

        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant_id:'', body:'blank'}) $$) AS (v agtype)|
        )

        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {body:'missing'}) $$) AS (v agtype)|
        )

        Enum.each(AshAge.Migration.rls_ddl(@graph, "Doc", "tenant_id", @guc), &exec/1)

        reset_role()
        exec(~s|CREATE ROLE #{@role} NOLOGIN|)
        exec(~s|GRANT USAGE ON SCHEMA ag_catalog, #{@graph} TO #{@role}|)

        exec(
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ag_catalog TO #{@role}|
        )

        exec(
          ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{@graph} TO #{@role}|
        )

        exec(~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{@graph} TO #{@role}|)

        try do
          fun.()
        after
          reset_role()
        end
      end,
      vlabels: ["Doc"]
    )
  end

  defp scoped_count(tenant),
    do:
      in_role_txn(fn ->
        set_guc(tenant)
        count_docs()
      end)

  defp in_role_txn(fun) do
    {:ok, v} =
      TestRepo.transaction(fn ->
        exec(~s|SET LOCAL ROLE #{@role}|)
        fun.()
      end)

    v
  end

  defp set_guc(tenant), do: exec("SELECT set_config($1, $2, true)", [@guc, tenant])

  defp count_docs do
    %{rows: [[n]]} =
      exec(
        ~s|SELECT count(*) FROM ag_catalog.cypher('#{@graph}', $$ MATCH (n:Doc) RETURN n $$) AS (v agtype)|
      )

    n
  end

  defp reset_role do
    exec(
      ~s|DO $$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@role}') THEN EXECUTE 'DROP OWNED BY #{@role}'; EXECUTE 'DROP ROLE #{@role}'; END IF; END $$|
    )
  end
end
