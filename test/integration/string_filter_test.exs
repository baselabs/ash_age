defmodule AshAge.Integration.StringFilterTest do
  @moduledoc """
  Live-AGE conformance for the string-function predicates (contains /
  string_starts_with / string_ends_with) on the read path: parameterized
  CONTAINS / STARTS WITH / ENDS WITH WHERE clauses, case-SENSITIVE semantics
  (openCypher's operators), and NOT-wrapped negation.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  defmodule Item do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_strfilter)
      repo(AshAge.TestRepo)
      label(:Item)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create])
    end
  end

  setup do
    :ok
  end

  test "contains/starts_with/ends_with filter reads, case-sensitively, with negation" do
    with_graph(
      "itest_strfilter",
      fn ->
        Enum.each(["Alpha One", "alpha two", "Beta Three"], fn name ->
          {:ok, _} = Item |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create()
        end)

        names = fn query -> query |> Ash.read!() |> Enum.map(& &1.name) |> Enum.sort() end

        # CONTAINS — case-sensitive on both cases
        assert names.(Ash.Query.filter(Item, contains(name, "Alpha"))) == ["Alpha One"]
        assert names.(Ash.Query.filter(Item, contains(name, "alpha"))) == ["alpha two"]

        # STARTS WITH / ENDS WITH
        assert names.(Ash.Query.filter(Item, string_starts_with(name, "Alp"))) == ["Alpha One"]
        assert names.(Ash.Query.filter(Item, string_ends_with(name, "two"))) == ["alpha two"]
        assert names.(Ash.Query.filter(Item, string_ends_with(name, "Three"))) == ["Beta Three"]

        # NOT contains
        assert names.(Ash.Query.filter(Item, not contains(name, "a"))) == []

        assert names.(Ash.Query.filter(Item, not contains(name, "zzz"))) ==
                 ["Alpha One", "Beta Three", "alpha two"]

        # composed with a boolean operator
        assert names.(Ash.Query.filter(Item, contains(name, "One") or contains(name, "Three"))) ==
                 ["Alpha One", "Beta Three"]
      end,
      vlabels: ["Item"]
    )
  end
end
