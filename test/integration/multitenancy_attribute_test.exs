defmodule AshAge.Integration.MultitenancyAttributeTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule Note do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s3_attr)
      repo(AshAge.TestRepo)
      label(:Note)
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

  @org_a "11111111-1111-1111-1111-111111111111"
  @org_b "22222222-2222-2222-2222-222222222222"

  test "attribute tenancy isolates reads/create/update/destroy across tenants (UUID tenant)" do
    with_graph(
      "itest_s3_attr",
      fn ->
        {:ok, a} =
          Note
          |> Ash.Changeset.for_create(:create, %{body: "a"}, tenant: @org_a)
          |> Ash.create()

        {:ok, _b} =
          Note
          |> Ash.Changeset.for_create(:create, %{body: "b"}, tenant: @org_b)
          |> Ash.create()

        # Read isolation: tenant A sees only its own row.
        assert {:ok, [only]} = Note |> Ash.Query.for_read(:read) |> Ash.read(tenant: @org_a)
        assert only.body == "a"

        # Update isolation: A's update cannot reach B's row (scoped by injected filter).
        assert {:ok, updated} =
                 a
                 |> Ash.Changeset.for_update(:update, %{body: "a2"}, tenant: @org_a)
                 |> Ash.update()

        assert updated.body == "a2"

        # Destroy isolation: destroying under A leaves B intact.
        :ok = a |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: @org_a) |> Ash.destroy()
        assert {:ok, []} = Note |> Ash.Query.for_read(:read) |> Ash.read(tenant: @org_a)
        assert {:ok, [_]} = Note |> Ash.Query.for_read(:read) |> Ash.read(tenant: @org_b)
      end,
      vlabels: ["Note"]
    )
  end

  # String-typed tenant (spec §9 requires BOTH UUID and string) — guards against
  # type-specific serialization of the discriminator property in the graph.
  defmodule Tag do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s3_attr_str)
      repo(AshAge.TestRepo)
      label(:Tag)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:account)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:account, :string, allow_nil?: false, public?: true)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  @acct_a "acme"
  @acct_b "globex"

  test "attribute tenancy isolates reads/create/update/destroy across tenants (string tenant)" do
    with_graph(
      "itest_s3_attr_str",
      fn ->
        {:ok, a} =
          Tag |> Ash.Changeset.for_create(:create, %{name: "a"}, tenant: @acct_a) |> Ash.create()

        {:ok, _b} =
          Tag |> Ash.Changeset.for_create(:create, %{name: "b"}, tenant: @acct_b) |> Ash.create()

        assert {:ok, [only]} = Tag |> Ash.Query.for_read(:read) |> Ash.read(tenant: @acct_a)
        assert only.name == "a"

        {:ok, updated} =
          a |> Ash.Changeset.for_update(:update, %{name: "a2"}, tenant: @acct_a) |> Ash.update()

        assert updated.name == "a2"

        :ok = a |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: @acct_a) |> Ash.destroy()
        assert {:ok, []} = Tag |> Ash.Query.for_read(:read) |> Ash.read(tenant: @acct_a)
        assert {:ok, [_]} = Tag |> Ash.Query.for_read(:read) |> Ash.read(tenant: @acct_b)
      end,
      vlabels: ["Tag"]
    )
  end
end
