defmodule AshAge.Integration.AggregateTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  # Plain (non-multitenant) resource for count/sum/avg/min/max/exists, sub-filters,
  # main-filter interaction, and the 0-row case.
  defmodule Item do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_aggregate
      repo AshAge.TestRepo
      label :Item
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :amount, :integer, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:name, :amount]
      defaults [:read]

      create :create do
        accept [:name, :amount]
      end
    end
  end

  # :attribute multitenant resource for the cross-tenant isolation tripwire (F4):
  # aggregate under tenant A must count ONLY A's rows even when B has rows too.
  defmodule TenantItem do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    age do
      graph :itest_aggregate_tenant
      repo AshAge.TestRepo
      label :TenantItem
    end

    attributes do
      attribute :org_id, :string, primary_key?: true, allow_nil?: false, public?: true
      uuid_primary_key :id
      attribute :amount, :integer, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:org_id, :amount]
      defaults [:read]

      create :create do
        accept [:org_id, :amount]
      end
    end
  end

  describe "count/sum/avg/min/max over the resource's own records" do
    test "count returns the number of matched vertices" do
      with_graph(:itest_aggregate, fn ->
        for amount <- [10, 20, 30], do: {:ok, _} = create(Item, %{amount: amount})

        assert {:ok, %{count: 3}} = Ash.aggregate(Item, {:count, :count})
      end)
    end

    test "sum/avg/min/max return the correct aggregate value" do
      with_graph(:itest_aggregate, fn ->
        for amount <- [10, 20, 30], do: {:ok, _} = create(Item, %{amount: amount})

        assert {:ok, %{total: 60}} = Ash.aggregate(Item, {:total, :sum, [field: :amount]})
        assert {:ok, %{mean: 20.0}} = Ash.aggregate(Item, {:mean, :avg, [field: :amount]})
        assert {:ok, %{lo: 10}} = Ash.aggregate(Item, {:lo, :min, [field: :amount]})
        assert {:ok, %{hi: 30}} = Ash.aggregate(Item, {:hi, :max, [field: :amount]})
      end)
    end

    test "exists returns a boolean (true when rows present, false when none)" do
      with_graph(:itest_aggregate, fn ->
        assert {:ok, %{any: false}} = Ash.aggregate(Item, {:any, :exists})

        {:ok, _} = create(Item, %{amount: 1})
        assert {:ok, %{any: true}} = Ash.aggregate(Item, {:any, :exists})
      end)
    end

    test "0-row count returns 0 (not an error)" do
      with_graph(:itest_aggregate, fn ->
        assert {:ok, %{count: 0}} = Ash.aggregate(Item, {:count, :count})
      end)
    end
  end

  describe "aggregate respects the main query filter" do
    test "count over a filtered query counts only matching rows (F6: ignores limit)" do
      with_graph(:itest_aggregate, fn ->
        for amount <- [10, 20, 30, 40], do: {:ok, _} = create(Item, %{amount: amount})

        # F6: the aggregate must ignore any limit on the query (count the FULL filtered set).
        query =
          Item
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(amount > 15)
          |> Ash.Query.limit(1)

        assert {:ok, %{big: 3}} = Ash.aggregate(query, {:big, :count})
      end)
    end

    test "aggregate with its own sub-filter narrows the set" do
      with_graph(:itest_aggregate, fn ->
        for {name, amount} <- [{"a", 10}, {"b", 20}, {"c", 30}] do
          {:ok, _} = create(Item, %{name: name, amount: amount})
        end

        assert {:ok, %{hi_count: 2}} =
                 Ash.aggregate(
                   Item,
                   {:hi_count, :count, query: [filter: [amount: [greater_than: 15]]]}
                 )
      end)
    end
  end

  describe "cross-tenant isolation (F4 tripwire)" do
    test ":attribute aggregate under tenant A counts ONLY A's rows" do
      with_graph(:itest_aggregate_tenant, fn ->
        org_a = "org-a"
        org_b = "org-b"

        # Seed 3 rows in A, 2 rows in B (both non-zero, distinct counts — F4 anti-vacuity).
        for _ <- 1..3, do: {:ok, _} = create(TenantItem, %{org_id: org_a, amount: 1}, org_a)
        for _ <- 1..2, do: {:ok, _} = create(TenantItem, %{org_id: org_b, amount: 1}, org_b)

        assert {:ok, %{count: 3}} = Ash.aggregate(TenantItem, {:count, :count}, tenant: org_a)
        # The binding assertion: a buggy unscoped count would return 5, not 3.
        refute match?(
                 {:ok, %{count: 5}},
                 Ash.aggregate(TenantItem, {:count, :count}, tenant: org_a)
               )
      end)
    end
  end

  # Binary-storage resource for the S7 aggregate guard (M1): min/max/sum/avg over
  # a binary attribute must be rejected — the stored `$age64$` base64 form is not
  # byte-order-preserving, so a comparison aggregate would silently return the
  # lexicographically-extreme base64 string (wrong value + type mismatch).
  defmodule Blob do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_aggregate_blob
      repo AshAge.TestRepo
      label :Blob
    end

    attributes do
      uuid_primary_key :id
      attribute :data, :binary, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:data]
      defaults [:read]

      create :create do
        accept [:data]
      end
    end
  end

  describe "S7 binary-storage guard (M1 tripwire)" do
    test "min/max/sum/avg over a binary field are rejected, not silently wrong" do
      with_graph(:itest_aggregate_blob, fn ->
        {:ok, _} = create(Blob, %{data: <<1, 2, 3>>})
        {:ok, _} = create(Blob, %{data: <<4, 5, 6>>})

        for kind <- [:min, :max, :sum, :avg] do
          assert {:error, _} = Ash.aggregate(Blob, {kind, kind, [field: :data]}),
                 "binary-field #{kind} aggregate should be rejected"
        end

        # count over binary-storage vertices is fine (counts vertices, not the field).
        assert {:ok, %{count: 2}} = Ash.aggregate(Blob, {:count, :count})
      end)
    end
  end

  defp create(resource, attrs, tenant \\ nil) do
    changeset = resource |> Ash.Changeset.for_create(:create, attrs)

    if tenant do
      Ash.create(changeset, tenant: tenant)
    else
      Ash.create(changeset)
    end
  end
end
