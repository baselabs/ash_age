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
end
