defmodule AshAge.Changes.CreateEdgeTest do
  use ExUnit.Case, async: true

  alias AshAge.Changes.CreateEdge
  alias AshAge.Edge
  alias AshAge.Type.Cast

  defmodule Src do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:ce_test)
      repo(AshAge.TestRepo)
      label(:Src)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  @edge %Edge{
    name: :rel,
    label: :RELATES,
    direction: :outgoing,
    destination: Src,
    properties: [:weight]
  }

  # A resource whose create action declares typed property arguments, so
  # `edge_properties/2` can be exercised over a real, cast changeset.
  defmodule Tagged do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:ce_tagged)
      repo(AshAge.TestRepo)
      label(:Tagged)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])

      create :make do
        argument(:photo, :binary)
        argument(:when, :utc_datetime)
        argument(:note, :string)
        argument(:friend_id, :string)
        argument(:friend_ids, {:array, :string})
      end
    end
  end

  @props_edge %Edge{
    name: :rel,
    label: :RELATES,
    direction: :outgoing,
    destination: Tagged,
    properties: [:photo, :when, :note]
  }

  test "builds a parameterized, identifier-validated outgoing CREATE with properties, no tenant clause for a non-multitenant resource" do
    {cypher, params} =
      CreateEdge.build_create(Src, @edge, %{"id" => "src-1"}, "dst-1", %{weight: 5}, nil)

    assert cypher =~ "MATCH (a:Src), (b:Src)"
    assert cypher =~ "a.id = $src_id AND b.id = $dst"
    assert cypher =~ "CREATE (a)-[e:RELATES]->(b)"
    assert cypher =~ "SET e.weight = $prop_weight"
    assert cypher =~ "RETURN e"
    refute cypher =~ "tenant"
    assert params == %{"src_id" => "src-1", "dst" => "dst-1", "prop_weight" => 5}
  end

  test "incoming direction reverses the arrow" do
    edge = %{@edge | direction: :incoming, properties: []}
    {cypher, _} = CreateEdge.build_create(Src, edge, %{"id" => "s"}, "d", %{}, nil)
    assert cypher =~ "CREATE (b)-[e:RELATES]->(a)"
  end

  test ":both writes as outgoing" do
    edge = %{@edge | direction: :both, properties: []}
    {cypher, _} = CreateEdge.build_create(Src, edge, %{"id" => "s"}, "d", %{}, nil)
    assert cypher =~ "CREATE (a)-[e:RELATES]->(b)"
  end

  test ":attribute tenancy scopes BOTH endpoints by the tenant discriminator" do
    # tenant tuple: {source_attr, dest_attr, tenant_value}
    {cypher, params} =
      CreateEdge.build_create(Src, @edge, %{"id" => "s"}, "d", %{}, {:org_id, :org_id, "t1"})

    assert cypher =~ "a.org_id = $tenant AND b.org_id = $tenant"
    assert params["tenant"] == "t1"
  end

  describe "edge_properties/2 serializes by declared argument type" do
    @raw_photo <<0xFF, 0x00, 0xAB>>

    defp props_changeset(args) do
      Ash.Changeset.for_create(Tagged, :make, args)
    end

    test "binary property is $age64$-tagged (not raw bytes)" do
      changeset = props_changeset(%{photo: @raw_photo})
      props = CreateEdge.edge_properties(changeset, @props_edge)

      # Byte-identical to how the vertex path stores a binary attribute.
      assert props[:photo] == Cast.encode_binary(@raw_photo)
      assert String.starts_with?(props[:photo], "$age64$")
      # Non-vacuity: the raw bytes are NOT stored (pre-fix behavior).
      refute props[:photo] == @raw_photo
    end

    test "datetime property is ISO8601 (not a struct)" do
      when_dt = ~U[2026-07-01 12:00:00Z]
      changeset = props_changeset(%{when: when_dt})
      props = CreateEdge.edge_properties(changeset, @props_edge)

      assert props[:when] == DateTime.to_iso8601(when_dt)
      # Non-vacuity: the struct itself is NOT stored (pre-fix behavior).
      refute props[:when] == when_dt
    end

    test "string property is unchanged" do
      changeset = props_changeset(%{note: "hello"})
      props = CreateEdge.edge_properties(changeset, @props_edge)
      assert props[:note] == "hello"
    end

    test "an unsupplied property argument is rejected (absent from the map)" do
      changeset = props_changeset(%{note: "only-note"})
      props = CreateEdge.edge_properties(changeset, @props_edge)

      assert Map.has_key?(props, :note)
      refute Map.has_key?(props, :photo)
      refute Map.has_key?(props, :when)
    end
  end

  describe "destination_ids/2 resolves the `to:` argument" do
    test "a nil/unsupplied `to:` writes no edge (empty list)" do
      changeset = Ash.Changeset.for_create(Tagged, :make, %{})
      # Tripwire: nil `to:` MUST resolve to `[]` so zero edges are written and
      # the action still succeeds -- the edge is optional. Fails if someone
      # later makes a nil `to:` raise or write a bogus edge.
      assert CreateEdge.destination_ids(changeset, to: :friend_id) == []
    end

    test "a single `to:` value resolves to a one-element list" do
      changeset = Ash.Changeset.for_create(Tagged, :make, %{friend_id: "f-1"})
      assert CreateEdge.destination_ids(changeset, to: :friend_id) == ["f-1"]
    end

    test "a list `to:` value resolves to N ids" do
      changeset = Ash.Changeset.for_create(Tagged, :make, %{friend_ids: ["f-1", "f-2"]})
      assert CreateEdge.destination_ids(changeset, to: :friend_ids) == ["f-1", "f-2"]
    end
  end
end
