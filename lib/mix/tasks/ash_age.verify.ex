defmodule Mix.Tasks.AshAge.Verify do
  @shortdoc "Verifies AGE database configuration"

  @moduledoc """
  Verifies that Apache AGE is properly configured in your database.

      $ mix ash_age.verify

  Connects to the database and checks:

  1. The AGE extension is installed
  2. The search_path includes `ag_catalog`
  3. (Optional) A specific graph exists
  4. (Optional) A resource's label table has a matching tenant RLS policy (drift check)

  ## Options

  - `-r`, `--repo` — The repo to verify against
  - `-g`, `--graph` — A graph name to check for existence
  - `--resource` — A resource module (e.g. `MyApp.Doc`) whose `rls_guc` RLS policy
    is checked against the DB: `row level security` must be enabled on the label
    table and a policy predicate must reference both the tenant property and the
    GUC. A mismatch is drift between the DSL and the DB.

  ## Examples

      $ mix ash_age.verify
      $ mix ash_age.verify --graph my_graph
      $ mix ash_age.verify -r MyApp.Repo -g my_graph
      $ mix ash_age.verify --resource MyApp.Doc
  """

  use Mix.Task

  alias Ecto.Adapters.SQL

  @impl Mix.Task
  def run(args) do
    {opts, _parsed} = parse_args!(args)

    repos = Mix.Ecto.parse_repo(args)
    repo = List.first(repos)
    Mix.Ecto.ensure_repo(repo, args)

    Mix.shell().info("Verifying AGE configuration for #{inspect(repo)}...\n")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        results = [
          check_age_extension(repo),
          check_search_path(repo),
          check_graph(repo, opts[:graph]),
          check_rls(repo, opts[:resource])
        ]

        failures = Enum.count(results, &(&1 == :error))

        Mix.shell().info("")

        if failures > 0 do
          # Per-check guidance was already printed above; raise so the task exits
          # non-zero (CI/precommit fail closed). Mix.shell().error alone writes to
          # stderr but leaves the exit status 0 — a drift a pipeline can't see.
          Mix.raise("#{failures} check(s) failed. See above for details.")
        else
          Mix.shell().info("All checks passed!")
        end
      end)
  end

  @doc false
  def parse_args!(args) do
    OptionParser.parse!(args,
      strict: [repo: :string, graph: :string, resource: :string],
      aliases: [r: :repo, g: :graph]
    )
  end

  defp check_age_extension(repo) do
    query = """
    SELECT EXISTS (
      SELECT 1 FROM pg_extension WHERE extname = 'age'
    )
    """

    case SQL.query(repo, query, []) do
      {:ok, %{rows: [[true]]}} ->
        Mix.shell().info("  ✓ AGE extension is installed")
        :ok

      _ ->
        Mix.shell().error("  ✗ AGE extension is NOT installed")

        Mix.shell().info("    Run: CREATE EXTENSION IF NOT EXISTS age; in your database")

        :error
    end
  end

  defp check_search_path(repo) do
    case SQL.query(repo, "SHOW search_path", []) do
      {:ok, %{rows: [[path]]}} ->
        if String.contains?(path, "ag_catalog") do
          Mix.shell().info("  ✓ search_path includes ag_catalog (#{path})")
          :ok
        else
          Mix.shell().error("  ✗ search_path does NOT include ag_catalog (#{path})")

          Mix.shell().info(
            "    Add to your Repo config: after_connect: {AshAge.Session, :setup, []}"
          )

          :error
        end

      {:error, reason} ->
        Mix.shell().error("  ✗ Could not check search_path: #{inspect(reason)}")
        :error
    end
  end

  defp check_graph(_repo, nil), do: :ok

  defp check_graph(repo, graph_name) do
    AshAge.Migration.validate_identifier!(graph_name)

    if AshAge.Graph.exists?(repo, graph_name) do
      Mix.shell().info("  ✓ Graph #{inspect(graph_name)} exists")
      :ok
    else
      Mix.shell().error("  ✗ Graph #{inspect(graph_name)} does NOT exist")
      Mix.shell().info("    Create it via migration: create_age_graph(#{inspect(graph_name)})")
      :error
    end
  end

  defp check_rls(_repo, nil), do: :ok

  defp check_rls(repo, resource_str) do
    # Resolve/validate the module BEFORE any Info/Ash.Resource.Info accessor — those
    # raise `ArgumentError: not a Spark DSL module` on a typo'd or non-resource name,
    # which would surface a raw stacktrace AND short-circuit the other checks. Fail as
    # a clean :error so it flows through the normal aggregation + Mix.raise instead.
    module = Module.concat([resource_str])

    if ash_age_resource?(module) do
      do_check_rls(repo, module, resource_str)
    else
      Mix.shell().error("  ✗ --resource #{resource_str}: not a loadable AshAge resource module")
      :error
    end
  end

  # Clean signal for an ash_age resource: loaded + a Spark/Ash.Resource DSL module
  # (so `data_layer/1` won't raise) + its data layer is `AshAge.DataLayer`.
  defp ash_age_resource?(module) do
    Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Ash.Resource) and
      Ash.Resource.Info.data_layer(module) == AshAge.DataLayer
  end

  defp do_check_rls(repo, resource, resource_str) do
    guc = AshAge.DataLayer.Info.rls_guc(resource)

    cond do
      is_nil(guc) ->
        Mix.shell().info("  · #{resource_str} does not declare rls_guc (RLS check skipped)")
        :ok

      rls_policy_matches?(repo, resource_derived_args(resource, guc)) ->
        Mix.shell().info("  ✓ #{resource_str}: RLS enabled with a matching tenant policy")
        :ok

      true ->
        Mix.shell().error(
          "  ✗ #{resource_str}: rls_guc set but the label table lacks a matching RLS policy"
        )

        Mix.shell().info(
          "    Run AshAge.Migration.enable_tenant_rls(repo, #{resource_str}) in a migration"
        )

        :error
    end
  end

  # Derives (graph, label, tenant_property, guc) from the resource DSL — the SAME
  # four values `AshAge.Migration.enable_tenant_rls/2` uses to WRITE the policy, so
  # the check and the writer agree by construction.
  defp resource_derived_args(resource, guc) do
    graph = to_string(AshAge.DataLayer.Info.graph(resource))
    label = to_string(AshAge.DataLayer.Info.label(resource))
    prop = to_string(Ash.Resource.Info.multitenancy_attribute(resource))
    {graph, label, prop, guc}
  end

  @doc false
  # Drift check: TRUE iff the label table (schema=`graph`, table=`label`) has ROW
  # LEVEL SECURITY both ENABLEd AND FORCEd AND at least one policy whose USING
  # predicate text references BOTH the tenant property and the GUC. Postgres
  # normalizes the policy expression in `pg_policies.qual`; an
  # `AshAge.Migration.rls_ddl` policy's qual contains `'<guc>'` (the current_setting
  # arg) and `'"<prop>"'` (the agtype accessor key) — both LIKE-match here. A missing
  # table, disabled RLS, or a policy that references neither/only-one → FALSE (drift).
  #
  # FORCE is load-bearing, not cosmetic: with ENABLE alone the table OWNER bypasses
  # RLS (fact F), so an ENABLE-only table is the exact "RLS silently no-ops" hazard
  # this guard exists to catch — hence `relrowsecurity AND relforcerowsecurity`.
  # `enable_tenant_rls` always emits BOTH, so requiring FORCE keeps the check and the
  # writer in agreement by construction. Public (@doc false) so the live integration
  # test can assert match-vs-drift directly.
  def rls_policy_matches?(repo, {graph, label, prop, guc}) do
    query = """
    SELECT c.relrowsecurity AND c.relforcerowsecurity,
           coalesce(bool_or(p.qual LIKE '%' || $3 || '%' AND p.qual LIKE '%' || $4 || '%'), false)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_policies p ON p.schemaname = n.nspname AND p.tablename = c.relname
    WHERE n.nspname = $1 AND c.relname = $2
    GROUP BY c.relrowsecurity, c.relforcerowsecurity
    """

    case SQL.query(repo, query, [graph, label, prop, guc]) do
      {:ok, %{rows: [[true, true]]}} -> true
      _ -> false
    end
  end
end
