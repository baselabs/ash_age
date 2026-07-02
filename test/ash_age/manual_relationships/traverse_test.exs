defmodule AshAge.ManualRelationships.TraverseTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Resource.ManualRelationship.Context
  alias AshAge.Errors.QueryFailed
  alias AshAge.ManualRelationships.Traverse
  alias AshAge.Type.Vertex

  # ---- build_traverse/1 (pure Cypher builder) ----

  defp base_spec(overrides \\ %{}) do
    Map.merge(
      %{
        direction: :outgoing,
        edge_label: :LINK,
        min_depth: 1,
        max_depth: 3,
        src_label: "Node",
        dest_label: "Node",
        src_pkey: [:id],
        tenant_attr: nil,
        tenant: nil,
        per_hop_scope?: false,
        ids: [%{"id" => "a"}]
      },
      overrides
    )
  end

  test "outgoing builds a directed variable-length pattern, UNWIND source-match, scalar src return" do
    {cypher, params} = Traverse.build_traverse(base_spec())

    assert cypher =~ "UNWIND $ids AS sid"
    assert cypher =~ "MATCH (a:Node)-[:LINK*1..3]->(b:Node)"
    assert cypher =~ "WHERE a.id = sid.id"
    assert cypher =~ "RETURN a.id AS s1, b"
    # No SQL DISTINCT — per-path rows are returned so row_count is pre-dedup (§5.4).
    refute cypher =~ "DISTINCT"
    # never-interpolate: the id VALUE lives only in params, referenced as $ids.
    assert cypher =~ "$ids"
    assert params == %{"ids" => [%{"id" => "a"}]}
    refute cypher =~ ~s(= "a")
    # No bound path variable — this AGE build rejects `p =` + ALL(nodes(p)) (probe P-S5b).
    refute cypher =~ "p ="
  end

  test "incoming reverses the arrow" do
    {cypher, _} = Traverse.build_traverse(base_spec(%{direction: :incoming}))
    assert cypher =~ "MATCH (a:Node)<-[:LINK*1..3]-(b:Node)"
    refute cypher =~ "p ="
  end

  test "both is undirected (honors the S4 :both contract)" do
    {cypher, _} = Traverse.build_traverse(base_spec(%{direction: :both}))
    assert cypher =~ "MATCH (a:Node)-[:LINK*1..3]-(b:Node)"
    refute cypher =~ "->"
    refute cypher =~ "<-"
  end

  test "composite PK matches every field via sid.<field> and returns per-field scalars" do
    {cypher, params} =
      Traverse.build_traverse(
        base_spec(%{src_pkey: [:org_id, :node_id], ids: [%{"org_id" => "o", "node_id" => "n"}]})
      )

    assert cypher =~ "WHERE a.org_id = sid.org_id AND a.node_id = sid.node_id"
    assert cypher =~ "RETURN a.org_id AS s1, a.node_id AS s2, b"
    assert params == %{"ids" => [%{"org_id" => "o", "node_id" => "n"}]}
  end

  test ":attribute per-hop scope expands to a fixed-length UNION scoping every node (AGE lacks ALL(nodes(p)) — probe P-S5b)" do
    {cypher, params} =
      Traverse.build_traverse(
        base_spec(%{
          min_depth: 1,
          max_depth: 2,
          tenant_attr: "tenant_id",
          tenant: "t-1",
          per_hop_scope?: true
        })
      )

    # P-S5b = NO fallback: no bound path variable, no ALL(nodes(p)); one basic-MATCH
    # branch per length, UNION ALL'd, UNWIND repeated per branch, every node scoped.
    # `ALL(n` (not `ALL(`) so this doesn't false-fail on the `UNION ALL` keyword.
    refute cypher =~ "ALL(n"
    refute cypher =~ "nodes(p)"
    refute cypher =~ "p ="
    assert cypher =~ " UNION ALL "
    # 2 length branches => "UNWIND $ids AS sid" appears twice => 3 split parts.
    assert length(String.split(cypher, "UNWIND $ids AS sid")) == 3
    # L1: direct edge, both endpoints scoped.
    assert cypher =~ "MATCH (a:Node)-[:LINK]->(b:Node)"
    # L2: one unlabeled intermediate, all three nodes scoped.
    assert cypher =~ "MATCH (a:Node)-[:LINK]->(m1)-[:LINK]->(b:Node)"
    assert cypher =~ "a.tenant_id = $tenant"
    assert cypher =~ "m1.tenant_id = $tenant"
    assert cypher =~ "b.tenant_id = $tenant"
    assert cypher =~ "WHERE a.id = sid.id AND"
    assert cypher =~ "RETURN a.id AS s1, b"
    assert params == %{"ids" => [%{"id" => "a"}], "tenant" => "t-1"}
  end

  test "min_depth is honored in the pattern" do
    {cypher, _} = Traverse.build_traverse(base_spec(%{min_depth: 2, max_depth: 4}))
    assert cypher =~ "*2..4"
  end

  test "a non-identifier edge label is rejected" do
    assert_raise ArgumentError, fn ->
      Traverse.build_traverse(base_spec(%{edge_label: :"bad-label"}))
    end
  end

  # ---- validate_opts!/1 ----

  test "validate_opts! requires max_depth >= 1 and min <= max" do
    assert_raise ArgumentError, fn -> Traverse.validate_opts!(edge_label: :LINK, max_depth: 0) end

    assert_raise ArgumentError, fn ->
      Traverse.validate_opts!(edge_label: :LINK, max_depth: 2, min_depth: 3)
    end

    assert_raise ArgumentError, fn ->
      Traverse.validate_opts!(edge_label: :LINK, max_depth: :x)
    end

    assert_raise ArgumentError, fn -> Traverse.validate_opts!(max_depth: 2) end

    assert_raise ArgumentError, fn ->
      Traverse.validate_opts!(edge_label: :LINK, max_depth: 2, direction: :sideways)
    end

    assert {:LINK, :outgoing, 1, 2} = Traverse.validate_opts!(edge_label: :LINK, max_depth: 2)
  end

  # ---- scope_decision/4 (per-hop tenant-scope decision) ----

  test "scope_decision scopes when either endpoint is :attribute; none when neither" do
    # neither tenant-scoped by attribute -> no per-hop scope
    assert Traverse.scope_decision(nil, nil, nil, nil) == :none
    assert Traverse.scope_decision(:context, nil, :context, nil) == :none
    # self-referential :attribute (same discriminator) -> scope by it
    assert Traverse.scope_decision(:attribute, "org_id", :attribute, "org_id") == {:ok, "org_id"}
    # dest-only :attribute -> scope by dest
    assert Traverse.scope_decision(nil, nil, :attribute, "org_id") == {:ok, "org_id"}
    # source-only :attribute (dest not :attribute) -> scope by SOURCE (the fix:
    # this combo was previously left unscoped / fail-open)
    assert Traverse.scope_decision(:attribute, "org_id", nil, nil) == {:ok, "org_id"}
    assert Traverse.scope_decision(:attribute, "org_id", :context, nil) == {:ok, "org_id"}
  end

  test "scope_decision fails closed when both endpoints are :attribute with different discriminators" do
    # a single UNION scope can't honor two discriminator dimensions -> fail closed
    assert Traverse.scope_decision(:attribute, "org_id", :attribute, "account_id") ==
             {:error, :mixed_attribute}
  end

  # ---- assemble_rows/4 (F3 keying + dedup + cardinality) ----

  defp node_vertex_text(id_prop),
    do: ~s({"id": 1, "label": "Node", "properties": {"id": "#{id_prop}", "name": "n"}}::vertex)

  test "assemble_rows keys by %{pk => value} (F3), dedups by dest PK, :many => list" do
    rows = [
      [~s("a"), node_vertex_text("x")],
      # multi-path dup, same dest
      [~s("a"), node_vertex_text("x")],
      [~s("a"), node_vertex_text("y")],
      [~s("b"), node_vertex_text("z")]
    ]

    map =
      Traverse.assemble_rows(
        rows,
        %{src_pkey: [:id], dest_pkey: [:id], dest: __MODULE__.Fake},
        :many
      )

    assert map[%{id: "a"}] |> Enum.map(& &1.id) |> Enum.sort() == ["x", "y"]
    assert map[%{id: "b"}] |> Enum.map(& &1.id) == ["z"]
  end

  test "assemble_rows :one reduces each source to a single record" do
    rows = [[~s("a"), node_vertex_text("x")]]

    map =
      Traverse.assemble_rows(
        rows,
        %{src_pkey: [:id], dest_pkey: [:id], dest: __MODULE__.Fake},
        :one
      )

    assert %Vertex{} != map[%{id: "a"}]
    assert map[%{id: "a"}].id == "x"
  end

  test "assemble_rows coerces a date source PK so the F3 key matches the record's %Date{} key" do
    # AGE returns a date PK as an ISO8601 string; the in-struct source record
    # holds a %Date{} (normal reads run Cast.coerce_value). Ash associates manual
    # results by term equality, so the F3 key MUST be the coerced %Date{}, not the
    # raw string — otherwise the source is silently dropped (returns []/nil).
    rows = [[~s("2024-01-01"), node_vertex_text("x")]]

    map =
      Traverse.assemble_rows(
        rows,
        %{src_pkey: [:day], src_types: %{day: :date}, dest_pkey: [:id], dest: __MODULE__.Fake},
        :many
      )

    assert Map.keys(map) == [%{day: ~D[2024-01-01]}]
    assert map[%{day: ~D[2024-01-01]}] |> Enum.map(& &1.id) == ["x"]
    # NOT the raw-string key (the pre-fix bug).
    refute Map.has_key?(map, %{day: "2024-01-01"})
  end

  defmodule Fake do
    defstruct [:id, :name]
  end

  # ---- wrap_traverse_error/1 (RLS error routing: redact raw, pass built through) ----

  test "wrap_traverse_error redacts a raw Postgrex error, dropping the DETAIL leak vector" do
    # A raw DB error from SQL.query MUST be redacted. Postgres DETAIL/message echo
    # the offending values (the real leak vector, e.g. an RLS-denied tenant_id), so
    # populate them with a distinctive sentinel and prove it is DROPPED — only the
    # value-free SQLSTATE name surfaces. redact_db_error/1 reads only postgres.code
    # (+ constraint), never message/detail, so both sentinel fields must vanish.
    raw = %Postgrex.Error{
      message: "SECRET-LEAK-msg-9f2 row violates row-level security policy",
      postgres: %{
        code: :insufficient_privilege,
        message: "SECRET-LEAK-msg-9f2 row violates row-level security policy",
        detail: "Key (tenant_id)=(SECRET-LEAK-abc123) is not visible."
      }
    }

    assert %QueryFailed{query: "AGE traversal", reason: reason} =
             Traverse.wrap_traverse_error(raw)

    # SQLSTATE still surfaces (value-free), but neither DETAIL nor message leaks.
    assert reason == "database error (insufficient_privilege)"
    refute reason =~ "SECRET-LEAK-abc123"
    refute reason =~ "SECRET-LEAK-msg-9f2"
    refute reason =~ "tenant_id"
    refute reason =~ "Postgrex"
  end

  test "wrap_traverse_error passes an already-built exception through unchanged" do
    # unwrap_rls/2 returns a fully-built %QueryFailed{} for the blank-tenant /
    # set_config-rollback sentinels; wrap_traverse_error MUST NOT re-wrap or
    # re-redact it — the exception is forwarded verbatim.
    built = QueryFailed.exception(query: "RLS-scoped operation", reason: "tenant required")

    assert Traverse.wrap_traverse_error(built) == built
  end

  # ---- RLS routing (fail-closed, DB-free) ----

  # An :attribute source declaring rls_guc. rls_guc requires :attribute (S6
  # verifier), so a blank context.tenant fails closed BEFORE any query — no DB.
  defmodule RlsSource do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:traverse_rls)
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

    relationships do
      has_many :descendants, __MODULE__ do
        public?(true)

        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 2, min_depth: 1}
        )
      end
    end
  end

  test "an rls_guc :attribute source with a blank tenant fails closed (confidentiality tripwire)" do
    # Confidentiality tripwire on traverse's PRE-EXISTING fail-closed behavior: for
    # an rls_guc-declaring :attribute source with a blank context.tenant, load/3
    # returns a value-free %QueryFailed{}, no rows, and opens NO connection (this
    # runs in the unit lane with no DB, so any SQL.query would raise a DBConnection
    # error instead of returning this tuple). It short-circuits at resolve_tenant
    # (attribute_scope/2 -> {:error, tenant_required()}) BEFORE the query is built
    # and BEFORE with_rls is called — so this test does NOT exercise the with_rls
    # layer and would pass identically with the wrap removed. It guards that a
    # blank-tenant :attribute traversal can never touch the shared multi-tenant
    # graph. Scope of the other two layers:
    #   (a) the NEW with_rls-routing code's RED-capability is carried by the two
    #       wrap_traverse_error/1 tests above (the error-normalization seam);
    #   (b) live GUC enforcement (valid tenant -> GUC set on the pinned connection
    #       -> RLS-scoped traversal) needs a DB and is proven in the integration
    #       lane (Task 8). with_rls's own blank-tenant clause is structurally
    #       unreachable from traverse (both strategies fail closed upstream), so no
    #       DB-free unit test can isolate that layer.
    rel = ResourceInfo.relationship(__MODULE__.RlsSource, :descendants)

    records = [%{id: Ash.UUID.generate()}]

    context = %Context{relationship: rel, tenant: nil}

    opts = [edge_label: :LINK, direction: :outgoing, max_depth: 2, min_depth: 1]

    # The reason is the resolve_tenant short-circuit's ("multitenancy tenant
    # required"), NOT with_rls/unwrap_rls's blank-tenant reason ("... for
    # RLS-protected ..."), confirming this path fails closed before with_rls.
    assert {:error, %QueryFailed{reason: "multitenancy tenant required"}} =
             Traverse.load(records, opts, context)
  end
end
