defmodule AshAge.Changes.DestroyEdgeTest do
  use ExUnit.Case, async: true

  alias AshAge.Changes.DestroyEdge
  alias AshAge.Edge

  defmodule Src do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:de_test)
      repo(AshAge.TestRepo)
      label(:Src)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  @edge %Edge{name: :rel, label: :RELATES, direction: :outgoing, destination: Src, properties: []}

  test "builds a parameterized MATCH ... DELETE r RETURN r" do
    {cypher, params} = DestroyEdge.build_destroy(Src, @edge, %{"id" => "s"}, "d", nil)

    assert cypher =~ "MATCH (a:Src)-[r:RELATES]->(b:Src)"
    assert cypher =~ "a.id = $src_id AND b.id = $dst"
    assert cypher =~ "DELETE r RETURN r"
    assert params == %{"src_id" => "s", "dst" => "d"}
  end

  test ":attribute tenancy scopes both endpoints" do
    {cypher, params} =
      DestroyEdge.build_destroy(Src, @edge, %{"id" => "s"}, "d", {:org_id, :org_id, "t"})

    assert cypher =~ "a.org_id = $tenant AND b.org_id = $tenant"
    assert params["tenant"] == "t"
  end
end
