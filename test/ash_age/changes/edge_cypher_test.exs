defmodule AshAge.Changes.EdgeCypherTest do
  @moduledoc """
  Unit coverage for `AshAge.Changes.EdgeCypher` — the shared, security-critical
  edge-Cypher builders. Pins the identifier discipline: every property ref is
  backtick-quoted (a Cypher-keyword attribute name — `count`, `label` — must
  not emit a bare ref, which AGE mis-parses as a syntax error), and every VALUE
  rides a `$param`.
  """
  use ExUnit.Case, async: true

  alias AshAge.Changes.EdgeCypher

  describe "source_where/1" do
    test "backtick-quotes the source PK ref, value as param" do
      {clause, params} = EdgeCypher.source_where([{"count", 7}])

      assert clause == "a.`count` = $src_count"
      assert params == %{"src_count" => 7}
    end

    test "composite source PKs AND-join quoted refs" do
      {clause, _params} = EdgeCypher.source_where([{"label", "x"}, {"sum", 3}])

      assert clause == "a.`label` = $src_label AND a.`sum` = $src_sum"
    end
  end

  describe "tenant_where/1" do
    test "backtick-quotes both endpoint discriminator refs" do
      {clause, params} = EdgeCypher.tenant_where({"label", "count", "t1"})

      assert clause == " AND a.`label` = $tenant AND b.`count` = $tenant"
      assert params == %{"tenant" => "t1"}
    end

    test "non-multitenant destination takes no destination clause" do
      {clause, params} = EdgeCypher.tenant_where({"label", nil, "t1"})

      assert clause == " AND a.`label` = $tenant"
      assert params == %{"tenant" => "t1"}
    end
  end

  describe "tenant_spec/3 applies the source resource's parse_attribute (vertex-path parity)" do
    defmodule ParseTenant do
      def parse("org-" <> org), do: org
    end

    defmodule TenantSrc do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:edge_cypher_tenant_src)
        repo(AshAge.TestRepo)
        label(:Src)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:org, :string, public?: true)
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org)
        parse_attribute({ParseTenant, :parse, []})
      end

      actions do
        defaults([:create])
      end
    end

    @tenant_edge %AshAge.Edge{
      name: :rel,
      label: :REL,
      direction: :outgoing,
      destination: TenantSrc,
      properties: []
    }

    test "the scoped $tenant value is the PARSED tenant, not the raw to_tenant" do
      changeset =
        TenantSrc
        |> Ash.Changeset.for_create(:create, %{})
        |> Ash.Changeset.set_tenant("org-acme")

      {_src_attr, _dest_attr, value} = EdgeCypher.tenant_spec(TenantSrc, @tenant_edge, changeset)

      assert value == "acme"
    end

    test "a non-:attribute resource takes no tenant spec" do
      changeset = Ash.Changeset.new(AshAge.DataLayerTest.NoRlsResource)

      refute EdgeCypher.tenant_spec(AshAge.DataLayerTest.NoRlsResource, @tenant_edge, changeset)
    end
  end
end
