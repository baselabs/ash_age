defmodule AshAge.Integration.EdgeTenancyTest do
  @moduledoc """
  Live edge tenant-isolation tripwire for S4 — the edge analog of the S3
  cross-tenant WRITE test. Proves a cross-tenant edge link is REJECTED under both
  multitenancy strategies, and (independently, via a raw Cypher 0-row read) that
  NO edge landed. The error alone is insufficient: we assert the specific
  `InvalidRelationship` AND that no edge exists.

  `:context` — physical graph isolation. `CreateEdge` resolves the write graph via
  `write_graph/2`, which for `:context` returns the ACTING tenant's graph. A
  destination PK that only exists in ANOTHER tenant's graph simply isn't matched by
  the `MATCH (b) WHERE b.id = $dst` → 0 rows → `InvalidRelationship`.

  `:attribute` — one shared graph, row-level discriminator. `CreateEdge`'s
  `tenant_spec/3` emits `AND a.org_id = $tenant AND b.org_id = $tenant`; a
  destination owned by another org is excluded by the `b.org_id = $tenant` clause
  → 0 rows → `InvalidRelationship`. THIS is the cross-tenant-edge tripwire.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL

  # ------------------------------------------------------------------
  # :context resource — self-referential edge, two provisioned tenant graphs.
  # ------------------------------------------------------------------
  defmodule CtxNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s4_edge_ctx_base)
      repo(AshAge.TestRepo)
      label(:CtxNode)

      edge :link do
        label(:LINK)
        destination(CtxNode)
      end
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many(:link, __MODULE__, destination_attribute: :id)
    end

    actions do
      defaults([:read])

      create :create do
        accept([:name])
      end

      update :add_link do
        require_atomic?(false)
        argument(:link_id, :uuid)
        change({AshAge.Changes.CreateEdge, edge: :link, to: :link_id})
      end
    end
  end

  # ------------------------------------------------------------------
  # :attribute resource — self-referential edge, one shared graph, org_id
  # discriminator.
  # ------------------------------------------------------------------
  defmodule AttrNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s4_edge_attr)
      repo(AshAge.TestRepo)
      label(:AttrNode)

      edge :link do
        label(:LINK)
        destination(AttrNode)
      end
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
      has_many(:link, __MODULE__, destination_attribute: :id)
    end

    actions do
      defaults([:read])

      create :create do
        accept([:name])
      end

      update :add_link do
        require_atomic?(false)
        argument(:link_id, :uuid)
        change({AshAge.Changes.CreateEdge, edge: :link, to: :link_id})
      end
    end
  end

  @tenant_a "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @tenant_b "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

  @org_a "11111111-1111-1111-1111-111111111111"
  @org_b "22222222-2222-2222-2222-222222222222"

  # Graph teardown is registered at `setup_all` scope, NOT per-test — same lock-timing
  # discipline as the S3 context test: `drop_graph` needs an ACCESS EXCLUSIVE lock the
  # still-open per-test Sandbox owner transaction would block, so the drop must run
  # after every per-test owner transaction is gone. Graph DDL is not rolled back by the
  # Sandbox, so the unboxed drop is what cleans up.
  setup_all do
    ctx_graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)
    ctx_graph_b = AshAge.tenant_graph(CtxNode, @tenant_b)

    on_exit(fn ->
      SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{ctx_graph_a}', true)", [])
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{ctx_graph_b}', true)", [])
      end)
    end)

    :ok
  end

  setup do
    ctx_graph_a = AshAge.tenant_graph(CtxNode, @tenant_a)
    ctx_graph_b = AshAge.tenant_graph(CtxNode, @tenant_b)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      :ok =
        AshAge.Migration.provision_tenant(AshAge.TestRepo, ctx_graph_a,
          vlabels: ["CtxNode"],
          elabels: ["LINK"]
        )

      :ok =
        AshAge.Migration.provision_tenant(AshAge.TestRepo, ctx_graph_b,
          vlabels: ["CtxNode"],
          elabels: ["LINK"]
        )
    end)

    {:ok, ctx_graph_a: ctx_graph_a, ctx_graph_b: ctx_graph_b}
  end

  # --- helper: independent 0/N-row edge read through the library's own cypher seam ---
  defp edge_count(graph, dst_id) do
    {:ok, %{num_rows: n}} =
      cypher_query(
        graph,
        "MATCH (a:#{label(graph)})-[:LINK]->(b) WHERE b.id = $dst RETURN b",
        %{"dst" => dst_id}
      )

    n
  end

  # Both resources use a `LINK` edge but different vertex labels; the graph name
  # disambiguates which vertex label to match.
  defp label("itest_s4_edge_attr"), do: "AttrNode"
  defp label(_ctx_graph), do: "CtxNode"

  test ":context — cross-tenant edge link is rejected; no edge lands; same-tenant link succeeds",
       %{ctx_graph_a: ctx_graph_a} do
    # A vertex in each tenant's PHYSICALLY SEPARATE graph.
    {:ok, a} =
      CtxNode
      |> Ash.Changeset.for_create(:create, %{name: "a"}, tenant: @tenant_a)
      |> Ash.create()

    {:ok, b} =
      CtxNode
      |> Ash.Changeset.for_create(:create, %{name: "b"}, tenant: @tenant_b)
      |> Ash.create()

    # Cross-tenant: acting under tenant A, link A -> B where B lives ONLY in tenant B's
    # graph. `write_graph` resolves to A's graph; B's PK is absent there → 0 rows.
    assert {:error, %Ash.Error.Invalid{} = err} =
             a
             |> Ash.Changeset.for_update(:add_link, %{link_id: b.id}, tenant: @tenant_a)
             |> Ash.update()

    assert Enum.any?(
             List.wrap(err.errors),
             &match?(%Ash.Error.Changes.InvalidRelationship{}, &1)
           ),
           "expected InvalidRelationship for a cross-tenant edge write, got: #{inspect(err)}"

    # INDEPENDENT proof no edge landed: 0 edges into b.id in tenant A's graph.
    assert edge_count(ctx_graph_a, b.id) == 0

    # Same-tenant link SUCCEEDS and reads back only in tenant A's graph.
    {:ok, a2} =
      CtxNode
      |> Ash.Changeset.for_create(:create, %{name: "a2"}, tenant: @tenant_a)
      |> Ash.create()

    {:ok, _} =
      a
      |> Ash.Changeset.for_update(:add_link, %{link_id: a2.id}, tenant: @tenant_a)
      |> Ash.update()

    assert edge_count(ctx_graph_a, a2.id) == 1
  end

  test ":attribute — cross-tenant edge link is rejected; no edge lands; same-tenant link succeeds (TRIPWIRE)" do
    with_graph(
      "itest_s4_edge_attr",
      fn ->
        {:ok, v_a} =
          AttrNode
          |> Ash.Changeset.for_create(:create, %{name: "va"}, tenant: @org_a)
          |> Ash.create()

        {:ok, v_b} =
          AttrNode
          |> Ash.Changeset.for_create(:create, %{name: "vb"}, tenant: @org_b)
          |> Ash.create()

        # Cross-tenant: acting under org_a, link V_A -> V_B's PK. Both vertices live in
        # the SAME shared graph, so the only thing standing between them is the
        # `AND b.org_id = $tenant` discriminator clause. If that clause is wrong, this
        # link SUCCEEDS — a blocking cross-tenant-write defect.
        assert {:error, %Ash.Error.Invalid{} = err} =
                 v_a
                 |> Ash.Changeset.for_update(:add_link, %{link_id: v_b.id}, tenant: @org_a)
                 |> Ash.update()

        assert Enum.any?(
                 List.wrap(err.errors),
                 &match?(%Ash.Error.Changes.InvalidRelationship{}, &1)
               ),
               "expected InvalidRelationship for a cross-tenant edge write, got: #{inspect(err)}"

        # INDEPENDENT proof no edge landed: no (a)-[:LINK]->(b) where b.id = V_B.
        assert {:ok, %{num_rows: 0}} =
                 cypher_query(
                   "itest_s4_edge_attr",
                   "MATCH (a:AttrNode)-[:LINK]->(b) WHERE b.id = $dst RETURN b",
                   %{"dst" => v_b.id}
                 )

        # Same-org link SUCCEEDS: V_A -> another org_a vertex.
        {:ok, v_a2} =
          AttrNode
          |> Ash.Changeset.for_create(:create, %{name: "va2"}, tenant: @org_a)
          |> Ash.create()

        {:ok, _} =
          v_a
          |> Ash.Changeset.for_update(:add_link, %{link_id: v_a2.id}, tenant: @org_a)
          |> Ash.update()

        assert {:ok, %{num_rows: 1}} =
                 cypher_query(
                   "itest_s4_edge_attr",
                   "MATCH (a:AttrNode)-[:LINK]->(b) WHERE b.id = $dst RETURN b",
                   %{"dst" => v_a2.id}
                 )
      end,
      vlabels: ["AttrNode"],
      elabels: ["LINK"]
    )
  end
end
