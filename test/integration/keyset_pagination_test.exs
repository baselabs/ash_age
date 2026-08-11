defmodule AshAge.Integration.KeysetPaginationTest do
  @moduledoc """
  Verifies Ash keyset pagination works against AGE.

  AshAge does NOT declare `can?(:keyset)` (the data-layer-native keyset path),
  so `Ash.Actions.Read.use_data_layer_keyset?/2` returns `false` and Ash takes
  the rewrite branch: it over-fetches by `limit + 1` and rewrites `page: [after:
  <keyset>]` into a compound sort + filter expression — `(rank > x) OR (rank ==
  x AND id > y)` — built from the standard comparison operators (`eq`, `gt`,
  `lt`, `is_nil`) and boolean expressions. AshAge's `can?/1` declares every one
  of those `true` (see `lib/data_layer.ex`), so the rewrite path is answerable
  without a native keyset capability. These tests prove that end-to-end on a
  live AGE graph.

  Why keyset matters: offset pagination compiles to Cypher `SKIP N`, which
  forces the planner to walk and discard the first N rows on every page — O(N)
  per page, O(N^2) to walk a large result set. Keyset compiles to a filter
  (`WHERE rank > $x`), which is indexable and constant-cost per page.
  """

  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule Ranked do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_keyset
      repo AshAge.TestRepo
      label :Ranked
    end

    attributes do
      uuid_primary_key :id
      attribute :rank, :integer, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:rank, :name]
      defaults [:create, :update, :destroy]

      read :read do
        primary? true
        pagination keyset?: true, default_limit: 100
      end
    end
  end

  # Insert ranks in deliberately scrambled order so a passing assertion can
  # only be explained by the sort driving the read order, not insertion order.
  @ranks_in_insertion_order [3, 1, 5, 2, 4]
  @ranks_sorted_asc Enum.sort(@ranks_in_insertion_order)
  @ranks_sorted_desc Enum.reverse(@ranks_sorted_asc)

  defp insert_all do
    for rank <- @ranks_in_insertion_order do
      {:ok, record} =
        Ranked
        |> Ash.Changeset.for_create(:create, %{rank: rank, name: "r#{rank}"})
        |> Ash.create()

      record
    end
  end

  defp ranks(page), do: Enum.map(page.results, & &1.rank)

  defp keyset_of(record), do: record.__metadata__[:keyset]

  test "keyset pagination walks the full set in sort order via page: [after: ...]" do
    with_graph("itest_keyset", fn ->
      insert_all()
      page_size = 2

      first =
        Ranked
        |> Ash.Query.sort(rank: :asc)
        |> Ash.read!(page: [limit: page_size])

      assert %Ash.Page.Keyset{} = first
      assert ranks(first) == Enum.take(@ranks_sorted_asc, page_size)
      assert first.more? == true
      # The rewrite branch attaches keysets in metadata even without can?(:keyset).
      assert Enum.all?(first.results, &(keyset_of(&1) != nil))

      second =
        Ranked
        |> Ash.Query.sort(rank: :asc)
        |> Ash.read!(page: [limit: page_size, after: keyset_of(List.last(first.results))])

      assert ranks(second) == Enum.drop(@ranks_sorted_asc, page_size) |> Enum.take(page_size)
      assert second.more? == true

      third =
        Ranked
        |> Ash.Query.sort(rank: :asc)
        |> Ash.read!(page: [limit: page_size, after: keyset_of(List.last(second.results))])

      # Final page is the remainder and signals no more rows.
      assert ranks(third) == [@ranks_sorted_asc |> List.last()]
      assert third.more? == false

      # Reassembling pages yields the complete set, in order, with no loss/dup.
      all = first.results ++ second.results ++ third.results
      assert ranks(%{results: all}) == @ranks_sorted_asc
      assert length(Enum.uniq(all)) == length(@ranks_in_insertion_order)
    end, vlabels: ["Ranked"])
  end

  test "page: [before: ...] walks backward in reverse sort order" do
    with_graph("itest_keyset", fn ->
      insert_all()

      # Walk forward to the last record, then use its keyset with :before to
      # pull the prior page. :before inverts the sort and the operator, so the
      # returned page is reversed back to ascending presentation order.
      [_r1, _r2, _r3, _r4, last] =
        Ranked
        |> Ash.Query.sort(rank: :asc)
        |> Ash.read!(page: [limit: 5])
        |> Map.get(:results)

      page =
        Ranked
        |> Ash.Query.sort(rank: :asc)
        |> Ash.read!(page: [limit: 2, before: keyset_of(last)])

      assert ranks(page) == [3, 4]
    end, vlabels: ["Ranked"])
  end

  test "explicit desc sort drives the keyset ordering and operator inversion" do
    with_graph("itest_keyset", fn ->
      insert_all()

      page =
        Ranked
        |> Ash.Query.sort(rank: :desc)
        |> Ash.read!(page: [limit: 2])

      assert ranks(page) == Enum.take(@ranks_sorted_desc, 2)

      next =
        Ranked
        |> Ash.Query.sort(rank: :desc)
        |> Ash.read!(page: [limit: 2, after: keyset_of(List.last(page.results))])

      assert ranks(next) == Enum.drop(@ranks_sorted_desc, 2) |> Enum.take(2)
    end, vlabels: ["Ranked"])
  end
end
