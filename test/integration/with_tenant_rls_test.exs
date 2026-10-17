defmodule AshAge.Integration.WithTenantRlsTest do
  @moduledoc """
  Live-AGE pins for `AshAge.with_tenant_rls/4`'s error contract (documented:
  "errors propagate raw"). A raising fun already re-raises through
  `Ecto.Repo.transaction`; a fun that ROLLS BACK with a value must surface that
  value as `{:error, reason}` — not crash with a bare `MatchError` that
  discards the reason (audit finding: the `{:ok, result} = repo.transaction(...)`
  match had no error branch).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.TestRepo

  @guc "ash_age.tenant_id"

  test "a raising fun propagates its own exception (documented raw propagation)" do
    assert_raise RuntimeError, "boom", fn ->
      AshAge.with_tenant_rls(TestRepo, @guc, "t1", fn -> raise "boom" end)
    end
  end

  test "a rolling-back fun returns {:error, reason}, preserving the reason" do
    assert {:error, :business_reason} =
             AshAge.with_tenant_rls(TestRepo, @guc, "t1", fn ->
               TestRepo.rollback(:business_reason)
             end)
  end
end
