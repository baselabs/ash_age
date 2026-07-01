defmodule AshAge.Integration.Probes.RlsEnforcementProbeTest do
  @moduledoc """
  Feasibility probe P3 (gates the whole S6 RLS defense-in-depth slice). It answers
  the make-or-break question: does `ag_catalog.cypher()` honor row-level security on
  the underlying label table?

  Verified mechanics (AGE 1.6.0 / PG16):
    * a STORED generated column can extract the tenant from `properties` via
      `btrim(ag_catalog.agtype_access_operator(properties, '"tenant"'::agtype)::text, '"')`
      (immutable-acceptable, yields the unquoted string);
    * with ENABLE + FORCE ROW LEVEL SECURITY and a GUC-keyed policy, a NON-SUPERUSER
      role sees only the rows matching `current_setting('ash_age.tenant_id')` through
      `cypher()` — superusers bypass RLS, so the app role must be non-superuser.

  A failure here would mean P3 = no and S6 is cut. This test passing records P3 = yes.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration
  @moduletag :probe

  @graph "itest_probe_p3"
  @role "ash_age_probe_role"

  test "P3: cypher() honors FORCE RLS + GUC under a non-superuser role" do
    with_graph(@graph, [vlabels: ["Doc"]], fn ->
      # Seed two tenants as the graph owner (owner writes bypass RLS by design here).
      exec(~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant:'t1', body:'a'}) $$) AS (v agtype)|)
      exec(~s|SELECT * FROM ag_catalog.cypher('#{@graph}', $$ CREATE (n:Doc {tenant:'t2', body:'b'}) $$) AS (v agtype)|)

      # Tenant discriminator as a generated column + FORCE RLS + symmetric GUC policy.
      exec(~s|ALTER TABLE #{@graph}."Doc" ADD COLUMN tenant_id text GENERATED ALWAYS AS (btrim(ag_catalog.agtype_access_operator(properties, '"tenant"'::agtype)::text, '"')) STORED|)
      exec(~s|ALTER TABLE #{@graph}."Doc" ENABLE ROW LEVEL SECURITY|)
      exec(~s|ALTER TABLE #{@graph}."Doc" FORCE ROW LEVEL SECURITY|)
      exec(~s|DROP POLICY IF EXISTS tenant_isol ON #{@graph}."Doc"|)
      exec(~s|CREATE POLICY tenant_isol ON #{@graph}."Doc" USING (tenant_id = current_setting('ash_age.tenant_id', true)) WITH CHECK (tenant_id = current_setting('ash_age.tenant_id', true))|)

      # Non-superuser role (superusers bypass RLS even under FORCE).
      exec(~s|DROP ROLE IF EXISTS #{@role}|)
      exec(~s|CREATE ROLE #{@role} NOLOGIN|)
      exec(~s|GRANT USAGE ON SCHEMA ag_catalog, #{@graph} TO #{@role}|)
      exec(~s|GRANT SELECT ON ALL TABLES IN SCHEMA ag_catalog TO #{@role}|)
      exec(~s|GRANT SELECT ON ALL TABLES IN SCHEMA #{@graph} TO #{@role}|)

      # Control: as the superuser owner, RLS is bypassed → both rows visible.
      assert count_docs() == 2

      try do
        exec(~s|SET ROLE #{@role}|)
        exec(~s|SET "ash_age.tenant_id" = 't1'|)
        # Under the non-superuser role, cypher() applies the policy → only tenant t1.
        assert count_docs() == 1
      after
        exec(~s|RESET ROLE|)
        exec(~s|RESET "ash_age.tenant_id"|)
        # A role holding granted privileges can't be dropped until they're released.
        exec(~s|DROP OWNED BY #{@role}|)
        exec(~s|DROP ROLE IF EXISTS #{@role}|)
      end
    end)
  end

  defp count_docs do
    %{rows: [[n]]} =
      exec(~s|SELECT count(*) FROM ag_catalog.cypher('#{@graph}', $$ MATCH (n:Doc) RETURN n $$) AS (v agtype)|)

    n
  end
end
