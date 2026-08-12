defmodule AshAge.Integration.PolicyAtomicUpdateTest do
  @moduledoc """
  End-to-end proof that a policy-authorized atomic update works (cross-vendor
  closeout should-fix). Advertising `:expr_error` flips Ash's single-record /
  bulk reroute to `authorize_changeset_with: :error`, which attaches Ash.Policy's
  wrapper `if policy_filter do true else error(...) end` to the query. The filter
  translator must strip that wrapper to the policy condition, or every authorized
  atomic update hard-errors. This test builds a real filter-producing policy and
  proves the policy filter gates the update (only authorized rows are touched).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  alias Ash.Query.Operator.Basic.Plus
  alias Ash.Query.Ref

  defp count_plus(n), do: %Plus{left: %Ref{attribute: %{name: :count}, relationship_path: []}, right: n}

  defmodule PolicyWidget do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    age do
      graph :itest_policy_atomic
      repo AshAge.TestRepo
      label :PolicyWidget
    end

    attributes do
      uuid_primary_key :id
      attribute :public, :boolean, allow_nil?: false, public?: true
      attribute :count, :integer, allow_nil?: false, public?: true
    end

    # A filter-producing policy: a row is readable/updatable iff `public == true`.
    # Ash expands this into the `if public == true do true else error(...) end`
    # wrapper on an authorized query. Create is permissive so setup can make a
    # private row (the read/update policy would otherwise block it).
    policies do
      policy action_type(:create) do
        authorize_if always()
      end

      policy action_type([:read, :update, :destroy]) do
        authorize_if expr(public == true)
      end
    end

    actions do
      default_accept [:public, :count]
      defaults [:read, :create, update: :*]
    end
  end

  test "a policy-authorized bulk_update applies the policy filter (wrapper stripped)" do
    with_graph(:itest_policy_atomic, fn ->
      actor = %{id: Ash.UUID.generate()}

      # Create WITHOUT authorize? so the private row (policy would block it) exists.
      {:ok, pub} = Ash.create(PolicyWidget, %{public: true, count: 1})
      {:ok, priv} = Ash.create(PolicyWidget, %{public: false, count: 1})

      # Atomic bulk_update WITH authorize?: true. If the policy wrapper is NOT
      # stripped, the filter translator rejects `if/3` and this hard-errors.
      # If it IS stripped, the WHERE carries `public == true` and only the
      # public row is updated.
      result =
        Ash.bulk_update(
          PolicyWidget,
          :update,
          %{count: count_plus(1)},
          actor: actor,
          authorize?: true,
          return_records?: true
        )

      assert %Ash.BulkResult{status: :success, error_count: 0} = result

      # The public row was updated (authorized by the policy filter), the private
      # row was NOT (the policy filter `public == true` excluded it). Read back
      # with authorize?: false so we can see both rows regardless of policy
      # (Ash.Policy scopes reads on an authorized resource even by default).
      by_id =
        PolicyWidget |> Ash.read!(authorize?: false) |> Map.new(&{&1.id, &1.count})

      assert by_id[pub.id] == 2
      assert by_id[priv.id] == 1
    end)
  end

  test "a policy-authorized single-record atomic update succeeds (wrapper strips)" do
    # The single-record reroute also gets the policy wrapper under authorize?: true.
    with_graph(:itest_policy_atomic, fn ->
      actor = %{id: Ash.UUID.generate()}
      {:ok, pub} = Ash.create(PolicyWidget, %{public: true, count: 5})

      # If the wrapper is NOT stripped, this hard-errors with UnsupportedFilter.
      assert {:ok, updated} =
               pub
               |> Ash.Changeset.for_update(:update)
               |> Ash.Changeset.atomic_update(:count, count_plus(1))
               |> Ash.update(actor: actor, authorize?: true)

      assert updated.count == 6
    end)
  end
end
