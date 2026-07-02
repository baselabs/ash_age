defmodule AshAge.DataLayerTest do
  use ExUnit.Case, async: true

  alias AshAge.DataLayer
  alias AshAge.Errors.QueryFailed
  alias AshAge.Query

  # A resource with NO rls_guc — RLS is off; with_rls/4 must run the fun verbatim.
  defmodule NoRlsResource do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:data_layer_no_rls)
      repo(AshAge.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  # An :attribute resource declaring rls_guc — RLS is on; with_rls/4 fails closed on
  # a blank tenant and otherwise sets the GUC inside a transaction. Satisfies the
  # Task-2 verifier (strategy :attribute + real attribute + rls_guc + not global).
  defmodule RlsResource do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:data_layer_rls)
      repo(AshAge.TestRepo)
      rls_guc("ash_age.tenant_id")
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tenant_id, :uuid, public?: true)
    end
  end

  describe "set_clauses/1" do
    test "builds n.key = $key fragments with parameterized values" do
      assert DataLayer.set_clauses(%{"name" => "x", "age" => 1}) in [
               "n.name = $name, n.age = $age",
               "n.age = $age, n.name = $name"
             ]
    end

    test "returns an empty string for no properties" do
      assert DataLayer.set_clauses(%{}) == ""
    end

    test "rejects a property key that is not a valid identifier (injection guard)" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        DataLayer.set_clauses(%{"name = 1 WITH n MATCH (x) DETACH DELETE x //" => "v"})
      end
    end
  end

  describe "can?/2 composite primary key" do
    test "declares composite-primary-key support (required for composite-PK resources to compile)" do
      assert DataLayer.can?(AshAge.DataLayer, :composite_primary_key)
    end
  end

  describe "pk_match_clause/2" do
    test "single :id key is byte-identical to the legacy hardcoded clause (backward compat)" do
      assert DataLayer.pk_match_clause([{:id, "u1"}], %{}) ==
               {"n.id = $match_id", %{"match_id" => "u1"}}
    end

    test "single non-:id key derives the predicate from the actual key name" do
      assert DataLayer.pk_match_clause([{:code, "abc"}], %{}) ==
               {"n.code = $match_code", %{"match_code" => "abc"}}
    end

    test "composite key ANDs both predicates with distinct params, declaration order preserved" do
      assert DataLayer.pk_match_clause([{:tenant_id, "t1"}, {:id, "u1"}], %{}) ==
               {"n.tenant_id = $match_tenant_id AND n.id = $match_id",
                %{"match_tenant_id" => "t1", "match_id" => "u1"}}
    end

    test "renames the match param when it would collide with a reserved (changed-attr) key" do
      assert DataLayer.pk_match_clause([{:id, "u1"}], %{"match_id" => "changed"}) ==
               {"n.id = $match_id_", %{"match_id_" => "u1"}}
    end

    test "rejects a primary-key field that is not a valid AGE identifier (injection guard)" do
      assert_raise ArgumentError, ~r/invalid AGE identifier/, fn ->
        DataLayer.pk_match_clause([{String.to_atom("id = 1 //"), "x"}], %{})
      end
    end

    test "raises when the resource declares no primary key (empty match is not valid Cypher)" do
      assert_raise ArgumentError, ~r/requires a primary key/, fn ->
        DataLayer.pk_match_clause([], %{})
      end
    end
  end

  describe "serialize_value/2" do
    test "tags and base64-encodes a :binary value so Jason can encode it (crash fix)" do
      raw = <<0, 255, 16, 128, 1>>
      encoded = DataLayer.serialize_value(raw, :binary)

      assert is_binary(encoded)
      # Self-identifying wire format: the "$age64$" tag marks a value ash_age
      # encoded, so read-back is deterministic — never a guess-decode of legacy
      # or externally-written data. The literal is pinned here on purpose.
      assert encoded == "$age64$" <> Base.encode64(raw)
      # The defect: Jason.encode! raises on the raw binary; the tagged form must not.
      assert is_binary(Jason.encode!(%{"payload" => encoded}))
    end

    test "handles the Ash.Type.Binary module type form as well" do
      raw = <<1, 2, 3>>
      assert DataLayer.serialize_value(raw, Ash.Type.Binary) == "$age64$" <> Base.encode64(raw)
    end

    test "leaves a plaintext :string value untouched (not base64-encoded)" do
      assert DataLayer.serialize_value("hello", :string) == "hello"
    end

    test "serializes datetimes to ISO8601 independent of the declared type" do
      assert DataLayer.serialize_value(~U[2026-06-30 12:00:00Z], :utc_datetime) ==
               "2026-06-30T12:00:00Z"
    end
  end

  describe "with_rls/4 + set_context/3 (RLS enforcement primitive)" do
    test "RLS off (no rls_guc) runs the fun verbatim, wrapped in {:ok, _}" do
      assert {:ok, :ran} =
               DataLayer.with_rls(NoRlsResource, "t1", AshAge.TestRepo, fn -> :ran end)
    end

    test "RLS on + blank tenant fails closed BEFORE running the fun (no DB touch)" do
      for blank <- [nil, ""] do
        assert {:error, :rls_tenant_required} =
                 DataLayer.with_rls(RlsResource, blank, AshAge.TestRepo, fn ->
                   flunk("must not run")
                 end)
      end
    end

    test "unwrap_rls maps the contract to callback results" do
      assert {:ok, :x} = DataLayer.unwrap_rls({:ok, {:ok, :x}}, RlsResource)
      assert :ok == DataLayer.unwrap_rls({:ok, :ok}, RlsResource)

      assert {:error, %QueryFailed{}} =
               DataLayer.unwrap_rls({:error, :rls_tenant_required}, RlsResource)
    end

    test "unwrap_rls passes a built exception through unchanged" do
      err = QueryFailed.exception(query: "q", reason: "boom")
      assert {:error, ^err} = DataLayer.unwrap_rls({:error, err}, RlsResource)
    end

    test "unwrap_rls is total: a bare driver rollback becomes a redacted QueryFailed (no leak)" do
      assert {:error, %QueryFailed{reason: reason}} =
               DataLayer.unwrap_rls({:error, :rollback}, RlsResource)

      # Value-free reason — must not echo the raw error term.
      assert is_binary(reason)
      refute reason =~ "rollback"
    end

    test "set_context/3 stashes context.private.tenant onto the query" do
      q = %Query{resource: RlsResource, graph: :g, label: :Doc, repo: AshAge.TestRepo}

      assert {:ok, %Query{tenant: "t9"}} =
               DataLayer.set_context(RlsResource, q, %{private: %{tenant: "t9"}})
    end

    test "empty bulk_create batch on an RLS-on resource returns the pre-S6 success (not a fail-closed error)" do
      # An empty batch has zero scoping surface (no DB touch, nothing written), so
      # it must NOT route into with_rls's blank-tenant fail-closed. It short-circuits
      # to the pre-S6 result `:ok` — the same as an RLS-off resource. This path is
      # DB-free (do_bulk_create(_, _, [], _) -> :ok), so no Sandbox is required.
      assert :ok == DataLayer.bulk_create(RlsResource, [], %{})
    end
  end

  describe "sort capability on binary storage (S7)" do
    test "binary storage is not sortable; everything else still is" do
      refute AshAge.DataLayer.can?(nil, {:sort, :binary})
      assert AshAge.DataLayer.can?(nil, {:sort, :string})
      assert AshAge.DataLayer.can?(nil, :sort)
    end
  end
end
