defmodule AshAge.Integration.Probes.RlsEnforcementProbeTest do
  @moduledoc """
  Feasibility probe P3 (gates the whole S6 RLS defense-in-depth slice). Answers the
  make-or-break question AND validates S6's exact runtime primitive:

    * a STORED generated column extracts the tenant as a `uuid` from `properties` via
      `btrim(ag_catalog.agtype_access_operator(properties, '"tenant_id"'::agtype)::text, '"')::uuid`
      — the `->>` operator isn't defined on agtype, so this is the immutable-acceptable
      equivalent, and it yields the spec's `::uuid` discriminator type;
    * with ENABLE + FORCE ROW LEVEL SECURITY and a policy keyed on
      `current_setting('ash_age.tenant_id')::uuid`, a NON-SUPERUSER role sees ONLY its
      own tenant's rows through `ag_catalog.cypher()`. The GUC and role are set with
      `SET LOCAL` inside a transaction — S6's transaction-boundary form — so they revert
      automatically and never leak onto the pooled connection, even on an abrupt kill.

  Result recorded: P3 = YES — `cypher()` honors RLS; S6 is viable.

  S6 still owns (NOT proven here): fail-closed on an empty/whitespace GUC (the `::uuid`
  cast errors on non-uuid input — S6 must choose clean-deny vs error), and re-applying
  the generated column + policy whenever a new (migration-declared) label table appears.

  Operational: this probe performs cluster-global `CREATE ROLE`/`DROP ROLE` and must only
  run against a throwaway AGE database. The app role MUST be non-superuser — superusers
  bypass RLS even under FORCE. AGE also rejects graph names shorter than 3 characters.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  @graph "itest_probe_p3"
  @role "ash_age_probe_role"
  @t1 "11111111-1111-1111-1111-111111111111"
  @t2 "22222222-2222-2222-2222-222222222222"

  test "P3: cypher() honors FORCE RLS + SET LOCAL GUC under a non-superuser role" do
    with_graph(
      @graph,
      fn ->
        # Seed two tenants as the graph owner (owner writes bypass RLS by design here).
        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant_id:'#{@t1}', body:'a'}) $$) AS (v agtype)|
        )

        exec(
          ~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant_id:'#{@t2}', body:'b'}) $$) AS (v agtype)|
        )

        # Tenant discriminator as a uuid generated column + FORCE RLS + symmetric GUC policy.
        exec(
          ~s|ALTER TABLE #{@graph}."Doc" ADD COLUMN tenant_id uuid GENERATED ALWAYS AS (btrim(ag_catalog.agtype_access_operator(properties, '"tenant_id"'::agtype)::text, '"')::uuid) STORED|
        )

        exec(~s|ALTER TABLE #{@graph}."Doc" ENABLE ROW LEVEL SECURITY|)
        exec(~s|ALTER TABLE #{@graph}."Doc" FORCE ROW LEVEL SECURITY|)

        exec(
          ~s|CREATE POLICY tenant_isol ON #{@graph}."Doc" USING (tenant_id = current_setting('ash_age.tenant_id', true)::uuid) WITH CHECK (tenant_id = current_setting('ash_age.tenant_id', true)::uuid)|
        )

        # Fresh non-superuser role (idempotent — cleans residue from any prior abrupt kill).
        reset_role()
        exec(~s|CREATE ROLE #{@role} NOLOGIN|)
        exec(~s|GRANT USAGE ON SCHEMA ag_catalog, #{@graph} TO #{@role}|)
        exec(~s|GRANT SELECT ON ALL TABLES IN SCHEMA ag_catalog TO #{@role}|)
        exec(~s|GRANT SELECT ON ALL TABLES IN SCHEMA #{@graph} TO #{@role}|)

        try do
          # Control: as the superuser owner, RLS is bypassed → both rows visible.
          assert count_docs() == 2

          # Under the non-superuser role with SET LOCAL GUC = t1, cypher() applies the
          # policy → exactly one visible row, and it is the CORRECT tenant (t1, not t2).
          TestRepo.transaction(fn ->
            exec(~s|SET LOCAL ROLE #{@role}|)
            exec(~s|SET LOCAL "ash_age.tenant_id" = '#{@t1}'|)

            assert count_docs() == 1

            %{rows: [[visible_tenant]]} = exec(~s|SELECT tenant_id::text FROM #{@graph}."Doc"|)
            assert visible_tenant == @t1
          end)
        after
          reset_role()
        end
      end,
      vlabels: ["Doc"]
    )
  end

  defp count_docs do
    %{rows: [[n]]} =
      exec(
        ~s|SELECT count(*) FROM ag_catalog.cypher('#{@graph}', $$ MATCH (n:Doc) RETURN n $$) AS (v agtype)|
      )

    n
  end

  # Drops the probe role and everything granted to it, if present — cluster-global, idempotent.
  defp reset_role do
    exec(
      ~s|DO $$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{@role}') THEN EXECUTE 'DROP OWNED BY #{@role}'; EXECUTE 'DROP ROLE #{@role}'; END IF; END $$|
    )
  end
end
