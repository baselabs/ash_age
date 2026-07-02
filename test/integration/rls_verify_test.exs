defmodule AshAge.Integration.RlsVerifyTest do
  @moduledoc """
  Live drift-detection proof for `mix ash_age.verify --resource` — specifically the
  `Mix.Tasks.AshAge.Verify.rls_policy_matches?/2` DB introspection that the task
  drives. A drift guard that cannot go RED on drift is vacuous, so this file proves
  BOTH directions against a REAL `AshAge.Migration.enable_tenant_rls/2` policy:

    * POSITIVE — after `enable_tenant_rls`, the label table has RLS enabled and a
      policy whose USING predicate references BOTH the tenant property and the GUC,
      so the introspection reports a MATCH.
    * NEGATIVE (the load-bearing one) — for an `rls_guc` resource/graph/label whose
      table has NO matching policy (RLS never enabled, or a policy that ignores the
      GUC), the introspection reports NO MATCH → drift DETECTED.

  Uses the DataCase `with_graph` harness on the real (unboxed) connection because
  RLS DDL (ALTER TABLE / CREATE POLICY) is not rolled back by the Sandbox.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias Mix.Tasks.AshAge.Verify

  # Reusable rls_guc resource. Satisfies the Task-2 verifier: `:attribute`
  # multitenancy (required for rls_guc), rls_guc declared, NOT `global?`.
  defmodule Doc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_rls_verify)
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

  # A minimal AshAge resource WITHOUT rls_guc — exercises check_rls's skip branch.
  defmodule NoRls do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_rls_verify_norls)
      repo(AshAge.TestRepo)
      label(:NoRls)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  @graph "itest_rls_verify"
  @label "Doc"
  # These mirror what `Verify.check_rls/2` derives from the resource DSL: the tenant
  # property is the `multitenancy attribute` (org_id), the GUC is `rls_guc`.
  @prop "org_id"
  @guc "ash_age.tenant_id"

  test "verify --resource drift check: MATCH after enable_tenant_rls, DRIFT when no policy" do
    with_graph(
      @graph,
      fn ->
        args = {@graph, @label, @prop, @guc}

        # --- NEGATIVE / DRIFT: no policy yet (label exists, RLS never enabled). ---
        # This is the load-bearing assertion: the guard MUST report NO match here,
        # otherwise it can never go red on real drift.
        #
        # RED discipline (quoted in the report): asserting `== true` here made the
        # test fail with `Assertion ... failed ... false`, proving the value is
        # genuinely `false` — so `refute` below is a non-vacuous drift detection.
        refute Verify.rls_policy_matches?(TestRepo, args),
               "expected DRIFT (no matching policy) before enable_tenant_rls, but the guard reported a match"

        # A policy that does NOT reference the GUC is ALSO drift (guard must not be
        # fooled by RLS-enabled + some-policy-present).
        exec(~s|ALTER TABLE #{@graph}."#{@label}" ENABLE ROW LEVEL SECURITY|)
        exec(~s|CREATE POLICY not_tenant ON #{@graph}."#{@label}" USING (true)|)

        refute Verify.rls_policy_matches?(TestRepo, args),
               "expected DRIFT (policy ignores the GUC), but the guard reported a match"

        exec(~s|DROP POLICY not_tenant ON #{@graph}."#{@label}"|)
        exec(~s|ALTER TABLE #{@graph}."#{@label}" DISABLE ROW LEVEL SECURITY|)

        # ENABLE without FORCE + a FULLY-matching tenant policy is STILL drift: the
        # table OWNER bypasses a merely-ENABLEd policy (fact F), so a guard that
        # accepts ENABLE-only would greenlight an owner-bypassable table — the exact
        # "RLS silently no-ops" hazard the feature warns about. The policy below
        # references BOTH the property and the GUC (so the qual substring match
        # passes); only the missing FORCE makes it drift.
        exec(~s|ALTER TABLE #{@graph}."#{@label}" ENABLE ROW LEVEL SECURITY|)

        exec(
          ~s|CREATE POLICY enable_only ON #{@graph}."#{@label}" USING (btrim(ag_catalog.agtype_access_operator(properties, '"#{@prop}"'::agtype)::text, '"') = current_setting('#{@guc}', true))|
        )

        refute Verify.rls_policy_matches?(TestRepo, args),
               "expected DRIFT (ENABLE without FORCE — the table owner bypasses RLS), but the guard reported a match"

        exec(~s|DROP POLICY enable_only ON #{@graph}."#{@label}"|)
        exec(~s|ALTER TABLE #{@graph}."#{@label}" DISABLE ROW LEVEL SECURITY|)

        # --- POSITIVE / MATCH: after the resource-derived enable_tenant_rls. ---
        :ok = AshAge.Migration.enable_tenant_rls(TestRepo, Doc)

        assert Verify.rls_policy_matches?(TestRepo, args),
               "expected a MATCH after enable_tenant_rls, but the guard reported drift"
      end,
      vlabels: [@label]
    )
  end

  # Exit-path proof (the gap the direct-call test above missed): a DETECTED drift
  # must make the TASK fail, not merely print to stderr. A drift guard that leaves
  # `mix ash_age.verify` at exit 0 is invisible to CI. `run/1` on a drifted resource
  # (rls_guc set, no matching policy) must raise `Mix.Error` (Mix.raise → non-zero
  # exit). This drives the REAL task's failure aggregation, not rls_policy_matches?/2.
  #
  # It also PINS the raise to the RLS-drift branch specifically (via the captured
  # `✗ ...RLS policy` line) so a future config change that makes a SIBLING check
  # (repo/extension/search_path) fail can't silently masquerade as this proof.
  test "run/1 RAISES on RLS drift specifically — pinned to the drift branch, not any failure" do
    # `@graph`'s label table has no policy here (no with_graph seeding), so check_rls
    # reports drift → the failure branch. `Mix.Ecto.parse_repo([])` resolves
    # AshAge.TestRepo from :ecto_repos, so no --repo flag is needed. Route shell
    # output to this process so we can assert the drift error line was emitted.
    prev = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      assert_raise Mix.Error, fn ->
        Verify.run(["--resource", "AshAge.Integration.RlsVerifyTest.Doc"])
      end

      assert_received {:mix_shell, :error,
                       [
                         "  ✗ AshAge.Integration.RlsVerifyTest.Doc: rls_guc set but the label table lacks a matching RLS policy"
                       ]}
    after
      Mix.shell(prev)
    end
  end

  # Skip-path coverage: a resource WITHOUT rls_guc must NOT fail the RLS check — it
  # emits the "skipped" info line and returns :ok. No `--graph` flag is passed, so the
  # graph check is a no-op; extension + search_path pass on the test DB. With the RLS
  # check skipped, the whole task passes (no raise). Pins the skip via the captured
  # "skipped" line, and the absence of any :error confirms it did not fail.
  test "check_rls skips (no failure) for a resource without rls_guc" do
    prev = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Verify.run(["--resource", "AshAge.Integration.RlsVerifyTest.NoRls"])

      assert_received {:mix_shell, :info,
                       [
                         "  · AshAge.Integration.RlsVerifyTest.NoRls does not declare rls_guc (RLS check skipped)"
                       ]}

      refute_received {:mix_shell, :error, _}
    after
      Mix.shell(prev)
    end
  end
end
