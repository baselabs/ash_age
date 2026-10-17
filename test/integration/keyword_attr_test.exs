defmodule AshAge.Integration.KeywordAttrTest do
  @moduledoc """
  Live-AGE conformance for Cypher-keyword attribute names (`count`, `label`,
  `sum`). 2.0.0 backtick-quoted the filter/sort/SET sides (`prop_ref`,
  `set_clauses`, the expr translator), but the mutation/traversal sides still
  emitted bare refs — `pk_match_clause` (`n.count = $match_count`), bulk-create
  SET (`n.count = row.count`), aggregates (`sum(n.sum)`), edge endpoint/property
  refs (`b.count = $dst`, `e.label = $prop_label`), and traversal PK matching
  (`a.count = sid.count`). A bare keyword ref is an AGE syntax error, so a
  resource whose OWN attribute names collide with Cypher keywords filtered fine
  and then failed on every mutation. This file pins the full round-trip.
  """
  use AshAge.DataCase, async: false
  require Ash.Query
  @moduletag :integration

  defmodule Item do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_kw)
      repo(AshAge.TestRepo)
      label(:Item)

      edge :rel do
        label(:REL)
        destination(Item)
        properties([:label])
      end
    end

    attributes do
      # Primary key literally named `count`, plus attrs named `label`/`sum` —
      # all three collide with Cypher keywords.
      attribute(:count, :integer,
        primary_key?: true,
        allow_nil?: false,
        public?: true,
        writable?: true
      )

      attribute(:label, :string, public?: true)
      attribute(:sum, :integer, public?: true)
    end

    relationships do
      has_many(:rel, __MODULE__, source_attribute: :count, destination_attribute: :count)

      has_many :kin, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           [edge_label: :REL, direction: :outgoing, max_depth: 1]}
        )
      end
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:count, :label, :sum])
      end

      update :update do
        primary?(true)
        require_atomic?(false)
        accept([:label, :sum])
      end

      destroy :destroy do
        primary?(true)
      end

      update :link do
        require_atomic?(false)
        argument(:to_count, :integer)
        # Edge property named `label` — a Cypher keyword — set on `e`.
        argument(:label, :string)
        change({AshAge.Changes.CreateEdge, edge: :rel, to: :to_count})
      end

      update :unlink do
        require_atomic?(false)
        argument(:to_count, :integer)
        change({AshAge.Changes.DestroyEdge, edge: :rel, to: :to_count})
      end
    end
  end

  # Seeds three items through single creates (the already-backticked set_clauses
  # path), so each test reds on ITS OWN target path, not the bulk-SET bug.
  defp seed do
    Enum.each(
      [
        %{count: 1, label: "one", sum: 10},
        %{count: 2, label: "two", sum: 20},
        %{count: 3, label: "three", sum: 30}
      ],
      fn attrs ->
        assert {:ok, _} = Item |> Ash.Changeset.for_create(:create, attrs) |> Ash.create()
      end
    )
  end

  test "update matches and SETs through a keyword-named primary key" do
    with_graph("itest_kw", fn ->
      seed()

      item = Item |> Ash.Query.filter(count == 1) |> Ash.read_one!()

      {:ok, updated} =
        item |> Ash.Changeset.for_update(:update, %{label: "uno"}) |> Ash.update()

      assert updated.label == "uno"
      assert updated.count == 1
    end)
  end

  test "destroy matches through a keyword-named primary key" do
    with_graph("itest_kw", fn ->
      seed()

      item = Item |> Ash.Query.filter(count == 3) |> Ash.read_one!()
      assert :ok = Ash.destroy(item)

      assert {:ok, nil} = Item |> Ash.Query.filter(count == 3) |> Ash.read_one()
    end)
  end

  test "bulk create SETs keyword-named attributes (UNWIND row refs)" do
    with_graph("itest_kw", fn ->
      rows = [%{count: 10, label: "ten", sum: 100}, %{count: 11, label: "eleven", sum: 110}]

      assert %Ash.BulkResult{status: :success, records: records} =
               Ash.bulk_create(rows, Item, :create, return_records?: true, transaction: :batch)

      assert Enum.map(records, & &1.count) == [10, 11]
    end)
  end

  test "aggregates over keyword-named fields (count(n.`count`), sum(n.`sum`))" do
    with_graph("itest_kw", fn ->
      seed()

      assert {:ok, %{c: 3}} = Ash.aggregate(Item, {:c, :count, [field: :count]})
      assert {:ok, %{t: 60}} = Ash.aggregate(Item, {:t, :sum, [field: :sum]})
    end)
  end

  test "edge CRUD with a keyword destination PK and keyword edge property" do
    with_graph("itest_kw", fn ->
      seed()

      one = Item |> Ash.Query.filter(count == 1) |> Ash.read_one!()
      two = Item |> Ash.Query.filter(count == 2) |> Ash.read_one!()

      # CREATE edge: b.`count` = $dst + SET e.`label` = $prop_label
      assert {:ok, _} =
               one
               |> Ash.Changeset.for_update(:link, %{to_count: two.count, label: "kin"})
               |> Ash.update()

      assert kin_counts(1) == [2]

      # DELETE edge: b.`count` = $dst
      assert {:ok, _} =
               one
               |> Ash.Changeset.for_update(:unlink, %{to_count: two.count})
               |> Ash.update()

      assert kin_counts(1) == []
    end)
  end

  test "traversal matches keyword-named source PKs (a.`count` = sid.`count`)" do
    with_graph("itest_kw", fn ->
      seed()

      one = Item |> Ash.Query.filter(count == 1) |> Ash.read_one!()
      two = Item |> Ash.Query.filter(count == 2) |> Ash.read_one!()

      assert {:ok, _} =
               one
               |> Ash.Changeset.for_update(:link, %{to_count: two.count, label: "kin"})
               |> Ash.update()

      assert kin_counts(1) == [2]
    end)
  end

  defp kin_counts(pk) do
    Item
    |> Ash.Query.filter(count == ^pk)
    |> Ash.read_one!()
    |> Ash.load!(:kin)
    |> Map.get(:kin)
    |> Enum.map(& &1.count)
  end
end
