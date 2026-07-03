defmodule AshAge.Integration.TraverseTest do
  @moduledoc """
  Live-AGE correctness + SECURITY proof surface for
  `AshAge.ManualRelationships.Traverse`: multi-hop reach, multi-path dedup, all
  three directions, composite + UUID source PK key-equality, binary-PK `$ids`
  encoding + F3 keyed-map round-trip (S7), nested-load-through-traversal
  in-tenant, the two cross-tenant tripwires (`:context` + `:attribute`),
  the `row_count` pre-dedup fan-out telemetry signal, and the two fail-closed
  blank-tenant paths. Edges are seeded via the library's own `cypher_query/3`
  seam (S5 dogfoods parameterized Cypher).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL

  # --- non-tenant resource: multi-hop, dedup, directions, UUID key-equality ---

  defmodule Node do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s5_traverse)
      repo(AshAge.TestRepo)
      label(:Node)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :descendants, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 2}
        )
      end

      has_many :descendants_1, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 1}
        )
      end

      has_many :ancestors, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :incoming, max_depth: 2}
        )
      end

      has_many :connected, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse, edge_label: :LINK, direction: :both, max_depth: 2}
        )
      end
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  # --- composite-PK non-tenant resource: proves sid.pk1 / sid.pk2 key-equality ---

  defmodule CDoc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s5_composite)
      repo(AshAge.TestRepo)
      label(:CDoc)
    end

    attributes do
      attribute(:org_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:node_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :descendants, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 2}
        )
      end
    end

    actions do
      default_accept([:org_id, :node_id, :name])
      defaults([:read, :destroy])

      create :create do
        accept([:org_id, :node_id, :name])
      end
    end
  end

  # --- :context resource: nested-load in-tenant + cross-tenant tripwire + fail-closed ---

  defmodule CtxNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s5_ctx_base)
      repo(AshAge.TestRepo)
      label(:CtxNode)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :descendants, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 2}
        )
      end
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  # --- :attribute resource: cross-tenant tripwire (test 8) + fail-closed (test 11) ---

  defmodule TNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s5_attr)
      repo(AshAge.TestRepo)
      label(:TNode)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, allow_nil?: false, public?: true)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :reachable, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 3}
        )
      end
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  # --- mixed multitenancy strategies: :attribute SOURCE -> non-tenant DEST ---
  # GNode is not multitenant but carries a plain `org_id` discriminator column
  # (same name as SNode's multitenancy attribute). Proves per-hop scoping fires
  # off the SOURCE strategy even when the DEST is not :attribute — a config that
  # was read UNSCOPED before the fix (resolve_tenant keyed on dest alone).

  defmodule GNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s5_mixed)
      repo(AshAge.TestRepo)
      label(:GNode)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, public?: true)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:org_id, :name])
      defaults([:read, :create, :destroy])
    end
  end

  defmodule SNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s5_mixed)
      repo(AshAge.TestRepo)
      label(:SNode)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :uuid, allow_nil?: false, public?: true)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many :globals, GNode do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :LINK, direction: :outgoing, max_depth: 1}
        )
      end
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :destroy])
    end
  end

  @tenant_a "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @tenant_b "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  @org_a "11111111-1111-1111-1111-111111111111"
  @org_b "22222222-2222-2222-2222-222222222222"

  # `:context` graph teardown lives at `setup_all` scope (a per-test drop
  # deadlocks the still-open Sandbox owner transaction — see the note in
  # multitenancy_context_test.exs). The graphs are provisioned per-test in `setup`
  # on an unboxed connection (graph DDL is not rolled back by the Sandbox).
  setup_all do
    graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)
    graph_b = AshAge.tenant_graph(CtxNode, @tenant_b)

    on_exit(fn ->
      SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{graph_a}', true)", [])
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{graph_b}', true)", [])
      end)
    end)

    :ok
  end

  # Provisions the two `:context` tenant graphs (idempotent) with the CtxNode
  # vertex + LINK edge labels. Only the tests using CtxNode read these; the
  # `with_graph/3`-based tests create their own graphs inline.
  defp provision_ctx do
    graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)
    graph_b = AshAge.tenant_graph(CtxNode, @tenant_b)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      :ok =
        AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_a,
          vlabels: ["CtxNode"],
          elabels: ["LINK"]
        )

      :ok =
        AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_b,
          vlabels: ["CtxNode"],
          elabels: ["LINK"]
        )
    end)
  end

  # Seeds a directed LINK edge between two Node/TNode/CtxNode vertices by PK `id`.
  defp link(graph, label, from_id, to_id) do
    {:ok, _} =
      cypher_query(
        graph,
        "MATCH (x:#{label} {id: $from}), (y:#{label} {id: $to}) CREATE (x)-[:LINK]->(y) RETURN 1",
        %{"from" => from_id, "to" => to_id}
      )
  end

  defp create!(resource, attrs, opts \\ []) do
    resource |> Ash.Changeset.for_create(:create, attrs, opts) |> Ash.create!()
  end

  # ===================================================================
  # Test 1 — multi-hop reach (max_depth bound)
  # ===================================================================
  test "multi-hop reach: max_depth 2 reaches {b,c}, max_depth 1 reaches {b}" do
    with_graph(
      "itest_s5_traverse",
      fn ->
        a = create!(Node, %{name: "a"})
        b = create!(Node, %{name: "b"})
        c = create!(Node, %{name: "c"})

        link("itest_s5_traverse", "Node", a.id, b.id)
        link("itest_s5_traverse", "Node", b.id, c.id)

        {:ok, [d2]} = Ash.load([a], :descendants)
        assert d2.descendants |> Enum.map(& &1.name) |> Enum.sort() == ["b", "c"]

        {:ok, [d1]} = Ash.load([a], :descendants_1)
        assert d1.descendants_1 |> Enum.map(& &1.name) |> Enum.sort() == ["b"]
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 2 — multi-path dedup (diamond)
  # ===================================================================
  test "multi-path dedup: d reachable via a->b->d and a->c->d appears exactly once" do
    with_graph(
      "itest_s5_traverse",
      fn ->
        a = create!(Node, %{name: "a"})
        b = create!(Node, %{name: "b"})
        c = create!(Node, %{name: "c"})
        d = create!(Node, %{name: "d"})

        link("itest_s5_traverse", "Node", a.id, b.id)
        link("itest_s5_traverse", "Node", a.id, c.id)
        link("itest_s5_traverse", "Node", b.id, d.id)
        link("itest_s5_traverse", "Node", c.id, d.id)

        {:ok, [loaded]} = Ash.load([a], :descendants)
        names = loaded.descendants |> Enum.map(& &1.name) |> Enum.sort()

        assert names == ["b", "c", "d"]
        assert Enum.count(loaded.descendants, &(&1.name == "d")) == 1
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 3 — directions (:outgoing, :incoming, :both)
  # ===================================================================
  test "directions: outgoing/incoming/both resolve per the S4-pinned contract" do
    with_graph(
      "itest_s5_traverse",
      fn ->
        a = create!(Node, %{name: "a"})
        b = create!(Node, %{name: "b"})

        # a -LINK-> b
        link("itest_s5_traverse", "Node", a.id, b.id)

        # :outgoing — a reaches b
        {:ok, [oa]} = Ash.load([a], :descendants)
        assert oa.descendants |> Enum.map(& &1.name) == ["b"]

        # :outgoing — b reaches nothing
        {:ok, [ob]} = Ash.load([b], :descendants)
        assert ob.descendants == []

        # :incoming — b reaches a (edge points a->b, so b's ancestor is a)
        {:ok, [ib]} = Ash.load([b], :ancestors)
        assert ib.ancestors |> Enum.map(& &1.name) == ["a"]

        # :incoming — a reaches nothing
        {:ok, [ia]} = Ash.load([a], :ancestors)
        assert ia.ancestors == []

        # :both — undirected: a reaches b AND b reaches a.
        {:ok, [ca]} = Ash.load([a], :connected)
        assert ca.connected |> Enum.map(& &1.name) == ["b"]
        {:ok, [cb]} = Ash.load([b], :connected)
        assert cb.connected |> Enum.map(& &1.name) == ["a"]
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 4 — composite PK (sid.pk1 / sid.pk2)
  # ===================================================================
  test "composite PK: traversal keyed on (org_id, node_id) associates the right source" do
    with_graph(
      "itest_s5_composite",
      fn ->
        # Two sources share node_id "root" but differ by org_id — a single-key
        # match would cross-associate them.
        a1 = create!(CDoc, %{org_id: "o1", node_id: "root", name: "a1"})
        a2 = create!(CDoc, %{org_id: "o2", node_id: "root", name: "a2"})
        _c1 = create!(CDoc, %{org_id: "o1", node_id: "child", name: "c1"})

        # Only the o1/root -> o1/child edge exists; o2/root (a2) has no edge.
        {:ok, _} =
          cypher_query(
            "itest_s5_composite",
            "MATCH (x:CDoc {org_id: $o1, node_id: $n1}), (y:CDoc {org_id: $o2, node_id: $n2}) " <>
              "CREATE (x)-[:LINK]->(y) RETURN 1",
            %{"o1" => "o1", "n1" => "root", "o2" => "o1", "n2" => "child"}
          )

        {:ok, [loaded]} = Ash.load([a1], :descendants)
        assert loaded.descendants |> Enum.map(& &1.name) == ["c1"]
        # And it is the RIGHT record by composite key.
        assert [%{org_id: "o1", node_id: "child"}] = loaded.descendants

        # Positive control: a2 shares node_id "root" but differs by org_id, so a
        # single-key (node_id-only) match would cross-associate a1's child onto
        # a2. The composite (org_id, node_id) key must leave a2's descendants empty.
        {:ok, [loaded_a2]} = Ash.load([a2], :descendants)
        assert loaded_a2.descendants == []
      end,
      vlabels: ["CDoc"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 5 — UUID source-PK key-equality (F3 key branch)
  # ===================================================================
  test "UUID source PK: loading multiple records associates each to its own descendants" do
    with_graph(
      "itest_s5_traverse",
      fn ->
        a = create!(Node, %{name: "a"})
        a_child = create!(Node, %{name: "a_child"})
        z = create!(Node, %{name: "z"})
        z_child = create!(Node, %{name: "z_child"})

        link("itest_s5_traverse", "Node", a.id, a_child.id)
        link("itest_s5_traverse", "Node", z.id, z_child.id)

        {:ok, loaded} = Ash.load([a, z], :descendants)
        by_name = Map.new(loaded, &{&1.name, &1.descendants |> Enum.map(fn d -> d.name end)})

        # Proves the decoded `src` string === the record's UUID PK — each source
        # maps to ITS OWN child, not the other's.
        assert by_name == %{"a" => ["a_child"], "z" => ["z_child"]}
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 6 — nested-load-through-traversal, in-tenant (:context)
  # ===================================================================
  test "nested load through traversal resolves the nested attr in the tenant's graph" do
    provision_ctx()
    graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)

    a = create!(CtxNode, %{name: "a"}, tenant: @tenant_a)
    b = create!(CtxNode, %{name: "b"}, tenant: @tenant_a)
    link(graph_a, "CtxNode", a.id, b.id)

    {:ok, [loaded]} = Ash.load([a], [descendants: [:name]], tenant: @tenant_a)
    assert loaded.descendants |> Enum.map(& &1.name) == ["b"]
  end

  # ===================================================================
  # Test 7 — cross-tenant tripwire, :context (physical graph isolation)
  # ===================================================================
  test "cross-tenant tripwire (:context): tenant A's traversal never returns B's nodes" do
    provision_ctx()
    graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)
    graph_b = AshAge.tenant_graph(CtxNode, @tenant_b)

    a = create!(CtxNode, %{name: "a"}, tenant: @tenant_a)
    a_child = create!(CtxNode, %{name: "a_child"}, tenant: @tenant_a)
    link(graph_a, "CtxNode", a.id, a_child.id)

    # Tenant B's nodes live in a physically separate graph, wired as a real
    # 2-node path (b -> b2) so the isolation proof is non-vacuous: B genuinely
    # has traversable data that A's traversal must never surface.
    b = create!(CtxNode, %{name: "b_secret"}, tenant: @tenant_b)
    b2 = create!(CtxNode, %{name: "b_secret2"}, tenant: @tenant_b)
    link(graph_b, "CtxNode", b.id, b2.id)

    {:ok, [loaded]} = Ash.load([a], :descendants, tenant: @tenant_a)
    names = loaded.descendants |> Enum.map(& &1.name)

    assert names == ["a_child"]
    refute Enum.any?(names, &String.starts_with?(&1, "b_secret"))
  end

  # ===================================================================
  # Test 8 — cross-tenant tripwire, :attribute (per-hop node scoping)
  # ===================================================================
  test "cross-tenant tripwire (:attribute): an out-of-band cross-tenant edge is not traversable" do
    with_graph(
      "itest_s5_attr",
      fn ->
        {:ok, a} =
          TNode |> Ash.Changeset.for_create(:create, %{name: "a"}, tenant: @org_a) |> Ash.create()

        {:ok, m} =
          TNode |> Ash.Changeset.for_create(:create, %{name: "m"}, tenant: @org_b) |> Ash.create()

        {:ok, c} =
          TNode |> Ash.Changeset.for_create(:create, %{name: "c"}, tenant: @org_a) |> Ash.create()

        # OUT-OF-BAND cross-tenant edges via raw Cypher, deliberately bypassing
        # the tenant-scoped CreateEdge change: a(org_a) -> m(org_b) -> c(org_a).
        {:ok, _} =
          cypher_query(
            "itest_s5_attr",
            "MATCH (x:TNode {id: $a}), (y:TNode {id: $m}) CREATE (x)-[:LINK]->(y) RETURN 1",
            %{"a" => a.id, "m" => m.id}
          )

        {:ok, _} =
          cypher_query(
            "itest_s5_attr",
            "MATCH (x:TNode {id: $m}), (y:TNode {id: $c}) CREATE (x)-[:LINK]->(y) RETURN 1",
            %{"m" => m.id, "c" => c.id}
          )

        {:ok, [loaded]} = Ash.load([a], :reachable, tenant: @org_a)

        # Per-hop scoping must exclude BOTH m (wrong tenant) AND c (same tenant
        # but reachable only THROUGH m). This assertion must hold identically
        # under the ALL(nodes(p)) path AND the P-S5b=NO UNION fallback — it is
        # the fail-closed guarantee, not an implementation detail.
        assert loaded.reachable == []
      end,
      vlabels: ["TNode"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 9 — row_count fan-out signal (pre-dedup > post-dedup)
  # ===================================================================
  test "row_count fan-out: diamond makes pre-dedup row_count exceed destination_count" do
    handler = "traverse-fanout-#{inspect(make_ref())}"
    parent = self()

    :telemetry.attach(
      handler,
      [:ash_age, :traverse, :stop],
      fn _event, _meas, meta, _ -> send(parent, {:traverse_stop, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    with_graph(
      "itest_s5_traverse",
      fn ->
        a = create!(Node, %{name: "a"})
        b = create!(Node, %{name: "b"})
        c = create!(Node, %{name: "c"})
        d = create!(Node, %{name: "d"})

        # Diamond: d reached via a->b->d AND a->c->d (two paths at depth 2).
        link("itest_s5_traverse", "Node", a.id, b.id)
        link("itest_s5_traverse", "Node", a.id, c.id)
        link("itest_s5_traverse", "Node", b.id, d.id)
        link("itest_s5_traverse", "Node", c.id, d.id)

        {:ok, [loaded]} = Ash.load([a], :descendants)
        assert loaded.descendants |> Enum.map(& &1.name) |> Enum.sort() == ["b", "c", "d"]

        assert_received {:traverse_stop, meta}
        # d contributes 2 pre-dedup rows (one per path) but 1 deduped dest, so
        # the pre-dedup fan-out strictly exceeds the deduped count.
        assert meta.row_count > meta.destination_count
        assert meta.destination_count == 3
        assert meta.result == :ok
        assert meta.depth == 2
      end,
      vlabels: ["Node"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 10 — fail-closed blank tenant, :context
  # ===================================================================
  test "fail-closed (:context): a blank tenant NEVER returns traversal results" do
    provision_ctx()
    graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)

    a = create!(CtxNode, %{name: "a"}, tenant: @tenant_a)
    b = create!(CtxNode, %{name: "b"}, tenant: @tenant_a)
    link(graph_a, "CtxNode", a.id, b.id)

    # A *loaded* record carries its origin tenant in its metadata, and Ash
    # re-supplies THAT tenant to the manual relationship even when the load opts
    # say `tenant: nil` — so `context.tenant` would arrive as tenant A and the
    # load would (correctly) return A's own data, never reaching our guard. To
    # drive a genuinely blank `context.tenant` we fabricate an *unstamped* struct
    # (same technique as the fabricated-attacker changeset in
    # multitenancy_attribute_test.exs) carrying A's id but NO tenant metadata.
    ghost = struct(CtxNode, id: a.id, name: "a", __meta__: %{state: :loaded})

    result =
      try do
        Ash.load([ghost], :descendants, tenant: nil)
      rescue
        e -> {:raised, e}
      end

    refute match?({:ok, [%{descendants: [_ | _]}]}, result),
           "blank-tenant :context traversal returned results (scoping hole): #{inspect(result)}"

    # Fail-closed via OUR guard: resolve_graph returns {:error, %QueryFailed{}}
    # ("multitenancy tenant required"), which Ash wraps as %Ash.Error.Invalid{}.
    assert {:error, %Ash.Error.Invalid{errors: errs}} = result

    assert Enum.any?(errs, &match?(%AshAge.Errors.QueryFailed{query: "AGE traversal"}, &1)),
           "expected our QueryFailed tenant-required guard, got: #{inspect(result)}"
  end

  # ===================================================================
  # Test 11 — fail-closed blank tenant, :attribute
  # ===================================================================
  test "fail-closed (:attribute): a blank tenant NEVER returns unscoped/cross-tenant data" do
    with_graph(
      "itest_s5_attr",
      fn ->
        {:ok, a} =
          TNode |> Ash.Changeset.for_create(:create, %{name: "a"}, tenant: @org_a) |> Ash.create()

        {:ok, child} =
          TNode |> Ash.Changeset.for_create(:create, %{name: "c"}, tenant: @org_a) |> Ash.create()

        {:ok, _} =
          cypher_query(
            "itest_s5_attr",
            "MATCH (x:TNode {id: $a}), (y:TNode {id: $c}) CREATE (x)-[:LINK]->(y) RETURN 1",
            %{"a" => a.id, "c" => child.id}
          )

        # Fabricate an unstamped struct (carrying A's id/org_id but NO tenant
        # metadata) so `context.tenant` reaches the manual relationship as nil and
        # exercises OUR resolve_tenant blank-tenant guard — a *loaded* record would
        # have Ash re-supply its origin tenant, bypassing the guard.
        ghost =
          struct(TNode, id: a.id, org_id: @org_a, name: "a", __meta__: %{state: :loaded})

        result =
          try do
            Ash.load([ghost], :reachable, tenant: nil)
          rescue
            e -> {:raised, e}
          end

        refute match?({:ok, [%{reachable: [_ | _]}]}, result),
               "blank-tenant :attribute traversal returned results (scoping hole): #{inspect(result)}"

        # Fail-closed via OUR guard: resolve_tenant returns {:error, %QueryFailed{}}.
        assert {:error, %Ash.Error.Invalid{errors: errs}} = result

        assert Enum.any?(errs, &match?(%AshAge.Errors.QueryFailed{query: "AGE traversal"}, &1)),
               "expected our QueryFailed tenant-required guard, got: #{inspect(result)}"
      end,
      vlabels: ["TNode"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 12 — :attribute POSITIVE control (builder UNION-ALL actually reaches)
  # ===================================================================
  # Test 8's cross-tenant tripwire asserts `reachable == []`; on its own that
  # cannot distinguish working per-node scoping from a wholly broken :attribute
  # path. This positive control proves the builder-emitted UNION-ALL query DOES
  # reach in-tenant nodes at every depth, so test 8's `[]` is a genuine exclusion.
  test ":attribute in-tenant traversal reaches every node at depth (builder positive control)" do
    with_graph(
      "itest_s5_attr",
      fn ->
        a = create!(TNode, %{name: "a"}, tenant: @org_a)
        b = create!(TNode, %{name: "b"}, tenant: @org_a)
        c = create!(TNode, %{name: "c"}, tenant: @org_a)

        link("itest_s5_attr", "TNode", a.id, b.id)
        link("itest_s5_attr", "TNode", b.id, c.id)

        {:ok, [loaded]} = Ash.load([a], :reachable, tenant: @org_a)
        assert loaded.reachable |> Enum.map(& &1.name) |> Enum.sort() == ["b", "c"]
      end,
      vlabels: ["TNode"],
      elabels: ["LINK"]
    )
  end

  # ===================================================================
  # Test 13 — mixed strategies: :attribute SOURCE scopes a non-tenant DEST
  # ===================================================================
  # SOURCE (SNode) is :attribute; DEST (GNode) is NOT multitenant but carries a
  # plain `org_id` discriminator. Before the fix, resolve_tenant keyed on dest
  # alone, so this ran UNSCOPED and returned g2 (the other tenant's row). After
  # the fix, per-hop scoping fires off the SOURCE strategy: g1 (same discriminator
  # as tenant A) is returned, g2 is excluded. Non-vacuous both ways — g1 present
  # (proves the query reaches) AND g2 absent (proves the scope fires).
  test "mixed strategies: an :attribute source scopes a non-:attribute destination" do
    with_graph(
      "itest_s5_mixed",
      fn ->
        a = create!(SNode, %{name: "a"}, tenant: @org_a)
        g1 = create!(GNode, %{name: "g1", org_id: @org_a})
        g2 = create!(GNode, %{name: "g2", org_id: @org_b})

        # a -> g1 (same discriminator) and a -> g2 (other tenant's discriminator).
        {:ok, _} =
          cypher_query(
            "itest_s5_mixed",
            "MATCH (x:SNode {id: $a}), (y:GNode {id: $g}) CREATE (x)-[:LINK]->(y) RETURN 1",
            %{"a" => a.id, "g" => g1.id}
          )

        {:ok, _} =
          cypher_query(
            "itest_s5_mixed",
            "MATCH (x:SNode {id: $a}), (y:GNode {id: $g}) CREATE (x)-[:LINK]->(y) RETURN 1",
            %{"a" => a.id, "g" => g2.id}
          )

        {:ok, [loaded]} = Ash.load([a], :globals, tenant: @org_a)
        names = loaded.globals |> Enum.map(& &1.name) |> Enum.sort()

        # g1 reached (query works), g2 excluded (source-driven scope fires).
        assert names == ["g1"]
      end,
      vlabels: ["SNode", "GNode"],
      elabels: ["LINK"]
    )
  end

  # --- binary-PK resource: S7 `$ids` encoding (tagged stored form must match) ---

  defmodule BinNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s7_bintrav)
      repo(AshAge.TestRepo)
      label(:BinNode)

      edge :links do
        label(:BINLINK)
        destination(__MODULE__)
      end
    end

    attributes do
      attribute(:key, :binary, primary_key?: true, allow_nil?: false, public?: true)
    end

    relationships do
      has_many :reachable, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :BINLINK, direction: :outgoing, max_depth: 2}
        )
      end

      has_many(:links, __MODULE__, source_attribute: :key, destination_attribute: :key)
    end

    actions do
      default_accept([:key])
      defaults([:read, :destroy])

      create :create do
        accept([:key])
        argument(:to, {:array, :binary})
        change({AshAge.Changes.CreateEdge, edge: :links, to: :to})
      end
    end
  end

  # ===================================================================
  # Test 14 — binary source PK: `$ids` carries the tagged stored form
  # ===================================================================
  test "traversal from a binary-PK source returns the F3 keyed map (S7 $ids encoding)" do
    a = <<0, 255, 10>>
    b = <<0, 255, 11>>

    with_graph(
      "itest_s7_bintrav",
      fn ->
        {:ok, _} = BinNode |> Ash.Changeset.for_create(:create, %{key: b}) |> Ash.create()

        {:ok, src} =
          BinNode |> Ash.Changeset.for_create(:create, %{key: a, to: [b]}) |> Ash.create()

        loaded = Ash.load!(src, :reachable)
        assert [%BinNode{key: ^b}] = loaded.reachable
      end,
      vlabels: ["BinNode"],
      elabels: ["BINLINK"]
    )
  end

  defmodule DayKey do
    use Ash.Type.NewType, subtype_of: :date
  end

  defmodule DateNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_datetrav)
      repo(AshAge.TestRepo)
      label(:DateNode)

      edge :links do
        label(:DAYLINK)
        destination(__MODULE__)
      end
    end

    attributes do
      attribute(:key, DayKey, primary_key?: true, allow_nil?: false, public?: true)
    end

    relationships do
      has_many :reachable, __MODULE__ do
        manual(
          {AshAge.ManualRelationships.Traverse,
           edge_label: :DAYLINK, direction: :outgoing, max_depth: 2}
        )
      end

      has_many(:links, __MODULE__, source_attribute: :key, destination_attribute: :key)
    end

    actions do
      default_accept([:key])
      defaults([:read, :destroy])

      create :create do
        accept([:key])
        argument(:to, {:array, DayKey})
        change({AshAge.Changes.CreateEdge, edge: :links, to: :to})
      end
    end
  end

  # ===================================================================
  # Test 15 — NewType-over-:date source PK: storage-class coercion keeps
  # the F3 keyed map keyed by %Date{} (pre-fix: coerce returned the ISO
  # STRING, so the map key never equaled the record key and the
  # relationship silently loaded empty — the silent-drop class in memory
  # ash-age-manual-rel-f3-key-coercion).
  # ===================================================================
  test "traversal from a NewType-date PK source returns the F3 keyed map" do
    a = ~D[2026-01-01]
    b = ~D[2026-01-02]

    with_graph(
      "itest_datetrav",
      fn ->
        {:ok, created_b} =
          DateNode |> Ash.Changeset.for_create(:create, %{key: b}) |> Ash.create()

        # read-back returns the STRUCT, not the ISO string (storage-class coercion)
        assert created_b.key == b
        assert [%DateNode{key: read_key} | _] = Ash.read!(DateNode)
        assert %Date{} = read_key

        {:ok, src} =
          DateNode |> Ash.Changeset.for_create(:create, %{key: a, to: [b]}) |> Ash.create()

        loaded = Ash.load!(src, :reachable)
        assert [%DateNode{key: ^b}] = loaded.reachable
      end,
      vlabels: ["DateNode"],
      elabels: ["DAYLINK"]
    )
  end
end
