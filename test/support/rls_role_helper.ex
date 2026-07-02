defmodule AshAge.RlsRoleHelper do
  @moduledoc """
  Shared harness for the S6 RLS integration tests.

  RLS applies only to a non-superuser role without `BYPASSRLS`; the test connection
  is the superuser graph owner (which `FORCE ROW LEVEL SECURITY` still lets bypass),
  so every RLS-enforcement assertion must run under a throwaway role via
  `SET LOCAL ROLE`. This module owns the ONE copy of that harness — `create_role/2`
  (grants), `reset_role/1` (the teardown `DO` block), and `in_role_txn/2` (the
  role-pinned transaction) — which was previously duplicated character-for-character
  across `rls_isolation_test`, `rls_data_layer_test`, and `rls_traverse_test`
  (only the role name and schema varied). Centralizing the teardown block removes
  the highest drift risk: a future hardening to one copy would otherwise silently
  miss the others.

  Like `AshAge.DataCase.with_graph/3`, the role and schema are passed through
  `AshAge.Migration.validate_identifier!/1` before interpolation, so this reusable
  helper never models an unchecked-interpolation pattern.
  """
  alias AshAge.DataCase
  alias AshAge.Migration

  @doc """
  Drops (via `reset_role/1`) then creates a throwaway `NOLOGIN` non-superuser role
  and grants it exactly the privileges an application connection needs on
  `ag_catalog` and the test graph's schema. Idempotent. Pair with `reset_role/1`
  in an `after`.
  """
  def create_role(role, graph) do
    role = Migration.validate_identifier!(role)
    graph = Migration.validate_identifier!(graph)

    reset_role(role)
    DataCase.exec(~s|CREATE ROLE #{role} NOLOGIN|)
    DataCase.exec(~s|GRANT USAGE ON SCHEMA ag_catalog, #{graph} TO #{role}|)

    DataCase.exec(
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ag_catalog TO #{role}|
    )

    DataCase.exec(
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{graph} TO #{role}|
    )

    DataCase.exec(~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA #{graph} TO #{role}|)
    :ok
  end

  @doc """
  Idempotently drops the throwaway role and everything it owns. The single copy of
  the teardown `DO` block previously duplicated across the three RLS test files.
  """
  def reset_role(role) do
    role = Migration.validate_identifier!(role)

    DataCase.exec(
      ~s|DO $$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN EXECUTE 'DROP OWNED BY #{role}'; EXECUTE 'DROP ROLE #{role}'; END IF; END $$|
    )
  end

  @doc """
  Runs `fun` inside a `TestRepo.transaction` after `SET LOCAL ROLE <role>`, so the
  body executes as the non-superuser role on one pinned connection (the topology
  under which RLS applies). Returns the raw `TestRepo.transaction/1` result
  (`{:ok, value}` / `{:error, reason}`) so callers can match on the shape they need.
  """
  def in_role_txn(role, fun) when is_function(fun, 0) do
    role = Migration.validate_identifier!(role)

    AshAge.TestRepo.transaction(fn ->
      DataCase.exec(~s|SET LOCAL ROLE #{role}|)
      fun.()
    end)
  end
end
