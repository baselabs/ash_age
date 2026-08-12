defmodule AshAge.Integration.ParamCollisionTest do
  @moduledoc """
  Tripwire for the `param<N>` attribute-name collision (cross-vendor finding).

  SET-attribute params use `$<attr>`; filter/PK/tenant scoping params use
  `$param<N>`. Without reservation, an attribute literally named `param<N>`
  shares its ref between the WHERE and the SET, and the merged params bind one
  value to both — a silent wrong-write. `reserve_attr_params/2` seeds every
  attribute name before scoping-param allocation so `$param<N>` skips them.

  This test would FAIL on the unfixed code (the filter grabs `$param1`, the SET
  of `:param1` gets the filter value) and PASSES with the fix (the filter grabs
  `$param2`, `:param1` keeps its SET value).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  # `:param1` is the collision bait — it matches the filter allocator's first
  # `$paramN` choice. `:flag` drives the filter (which allocates the param).
  defmodule ParamWidget do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_param_collision
      repo AshAge.TestRepo
      label :ParamWidget
    end

    attributes do
      uuid_primary_key :id
      attribute :param1, :integer, allow_nil?: false, public?: true
      attribute :flag, :string, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:param1, :flag]
      defaults [:read, :create, :destroy, update: :*]
    end
  end

  test "bulk_update setting a :param1 attr while filtering keeps the SET value" do
    with_graph(:itest_param_collision, fn ->
      {:ok, w} = Ash.create(ParamWidget, %{param1: 10, flag: "go"})

      # The filter `flag == "go"` allocates a scoping `$paramN`. Without the
      # reservation it would take `$param1` (the attr name) and clobber the SET.
      query = ParamWidget |> Ash.Query.for_read(:read) |> Ash.Query.filter(flag == "go")

      assert %Ash.BulkResult{status: :success, error_count: 0} =
               Ash.bulk_update(query, :update, %{param1: 99})

      # The SET value (99) must win — NOT the filter value ("go").
      assert Ash.get!(ParamWidget, w.id).param1 == 99
    end)
  end

  test "bulk_update filtering ON the :param1 attr still matches correctly" do
    # The reservation must not break filtering on the bait attr itself: the filter
    # `param1 == 10` allocates `$param2` (param1 reserved), so it scopes correctly.
    with_graph(:itest_param_collision, fn ->
      {:ok, w} = Ash.create(ParamWidget, %{param1: 10, flag: "go"})
      {:ok, other} = Ash.create(ParamWidget, %{param1: 20, flag: "go"})

      query = ParamWidget |> Ash.Query.for_read(:read) |> Ash.Query.filter(param1 == 10)

      assert %Ash.BulkResult{status: :success, error_count: 0} =
               Ash.bulk_update(query, :update, %{flag: "done"})

      assert Ash.get!(ParamWidget, w.id).flag == "done"
      # `other` (param1 == 20) NOT matched by the filter → unchanged.
      assert Ash.get!(ParamWidget, other.id).flag == "go"
    end)
  end
end
