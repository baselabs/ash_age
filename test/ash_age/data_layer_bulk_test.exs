defmodule AshAge.DataLayerBulkTest do
  use ExUnit.Case, async: true

  test "groups changeset property maps by key-set (no null-fill across groups)" do
    groups =
      AshAge.DataLayer.group_bulk_rows([
        %{"name" => "a", "tag" => "x"},
        %{"name" => "b"},
        %{"name" => "c", "tag" => "z"}
      ])

    # Two groups: {name,tag} and {name}. Each row keeps only its own keys.
    key_sets = groups |> Enum.map(fn {keys, _rows} -> Enum.sort(keys) end) |> Enum.sort()
    assert key_sets == [["name"], ["name", "tag"]]
  end

  test "empty input yields no groups (short-circuit)" do
    assert AshAge.DataLayer.group_bulk_rows([]) == []
  end

  test "rows sharing one key-set collapse into exactly one group (no over-split)" do
    groups =
      AshAge.DataLayer.group_bulk_rows([
        %{"name" => "a", "tag" => "x"},
        %{"name" => "b", "tag" => "y"},
        %{"name" => "c", "tag" => "z"}
      ])

    assert [{keys, rows}] = groups
    assert Enum.sort(keys) == ["name", "tag"]
    assert length(rows) == 3
  end

  test "can?(:bulk_create) is true" do
    assert AshAge.DataLayer.can?(nil, :bulk_create)
  end
end
