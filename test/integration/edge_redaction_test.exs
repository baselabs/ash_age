defmodule AshAge.Integration.EdgeRedactionTest do
  @moduledoc """
  Task 8 — the edge-write error surface is VALUE-FREE.

  Two live, non-vacuous proofs that an error raised during an `AshAge.Changes.CreateEdge`
  write never leaks a property value or a primary key into the surfaced Ash error:

    * Part A — the 0-row (destination-not-found) path. `add_friend` to a non-existent
      destination UUID, carrying a `since: "SECRET-since-value"` property, surfaces an
      `InvalidRelationship` whose full message contains NEITHER the property value NOR the
      destination UUID. Both values are genuinely bound into the failing changeset — a naive
      "not found: <dst>" message would echo the UUID — so the assertion is non-vacuous.

    * Part B — a GENUINE `%Postgrex.Error{}` on the edge-write path. A `:context` resource's
      source vertex is created in a PROVISIONED tenant graph, then `add_link` is invoked under
      a tenant whose graph is NEVER provisioned. `CreateEdge` resolves the edge write's graph
      from the ACTING tenant (`DataLayer.write_graph/2`), so the edge Cypher
      `MATCH (a:CtxNode), (b) ... CREATE (a)-[e:LINK]->(b) SET e.since = $prop_since` runs
      against a MISSING graph → Postgres `invalid_schema_name`. This lands in `create_one`'s
      `{:error, error}` branch, which routes through `DataLayer.redact_db_error/1`. The bound
      `since: "SECRET-since-value"` param IS sent to the failing query (verified via the query
      log), yet the surfaced message is the redacted `"database error (invalid_schema_name)"` —
      no `Postgrex`, no `DETAIL`, no property value, no PK.

  A leak here is a real defect in `lib/changes/create_edge.ex`'s error path, NOT a test to weaken.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL

  @secret "SECRET-since-value"

  # ------------------------------------------------------------------
  # Part A resource — single-graph Person with a `:friend` edge (T6 wiring).
  # ------------------------------------------------------------------
  defmodule Person do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_edge_redaction)
      repo(AshAge.TestRepo)
      label(:Person)

      edge :friend do
        label(:FRIEND)
        destination(Person)
        properties([:since])
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many(:friend, __MODULE__, destination_attribute: :id)
    end

    actions do
      defaults([:read])

      create :create do
        accept([:name])
      end

      update :add_friend do
        require_atomic?(false)
        argument(:friend_id, :uuid)
        argument(:since, :string)
        change({AshAge.Changes.CreateEdge, edge: :friend, to: :friend_id})
      end
    end
  end

  # ------------------------------------------------------------------
  # Part B resource — :context, self-referential edge, one provisioned tenant graph
  # plus one that is deliberately NEVER provisioned.
  # ------------------------------------------------------------------
  defmodule CtxNode do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_edge_redaction_ctx)
      repo(AshAge.TestRepo)
      label(:CtxNode)

      edge :link do
        label(:LINK)
        destination(CtxNode)
        properties([:since])
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
        argument(:since, :string)
        change({AshAge.Changes.CreateEdge, edge: :link, to: :link_id})
      end
    end
  end

  @tenant_provisioned "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  # Never provisioned — its graph does not exist, so the edge MATCH fails closed.
  @tenant_missing "cccccccc-cccc-cccc-cccc-cccccccccccc"

  # `drop_graph` needs an ACCESS EXCLUSIVE lock that a still-open per-test Sandbox owner
  # transaction (left behind by the failing Part B update) would block. So — exactly as the
  # S4 :context tenancy test does — the drop runs at `setup_all` on_exit, after every per-test
  # owner transaction is gone. Graph DDL is not rolled back by the Sandbox, so the unboxed drop
  # is what cleans up.
  setup_all do
    graph = AshAge.tenant_graph(CtxNode, @tenant_provisioned)

    on_exit(fn ->
      SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{graph}', true)", [])
      end)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Part A — 0-row destination-not-found path is value-free.
  # ---------------------------------------------------------------------------
  test "Part A: the destination-not-found (0-row) edge error leaks neither the property value nor the destination PK" do
    with_graph(
      "itest_edge_redaction",
      fn ->
        {:ok, a} = Person |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
        ghost = Ash.UUID.generate()

        assert {:error, %Ash.Error.Invalid{} = err} =
                 a
                 |> Ash.Changeset.for_update(:add_friend, %{friend_id: ghost, since: @secret})
                 |> Ash.update()

        # It IS the 0-row InvalidRelationship path (not some other failure).
        assert Enum.any?(
                 List.wrap(err.errors),
                 &match?(%Ash.Error.Changes.InvalidRelationship{}, &1)
               ),
               "expected InvalidRelationship for a 0-row edge write, got: #{inspect(err)}"

        message = Exception.message(err)

        # Non-vacuous: both the property value and the destination UUID are genuinely in the
        # changeset (a naive "not found: <dst>" message would echo the UUID). Neither surfaces.
        refute message =~ @secret,
               "property value leaked into the surfaced error: #{message}"

        refute message =~ ghost,
               "destination PK leaked into the surfaced error: #{message}"
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end

  # ---------------------------------------------------------------------------
  # Part B — a genuine Postgrex error on the edge-write path is redacted.
  # ---------------------------------------------------------------------------
  test "Part B: a genuine DB error during the edge write surfaces the redacted form, never Postgrex/DETAIL/value content" do
    graph = AshAge.tenant_graph(CtxNode, @tenant_provisioned)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      :ok =
        AshAge.Migration.provision_tenant(AshAge.TestRepo, graph,
          vlabels: ["CtxNode"],
          elabels: ["LINK"]
        )
    end)

    # Source and destination exist in the PROVISIONED tenant graph.
    {:ok, a} =
      CtxNode
      |> Ash.Changeset.for_create(:create, %{name: "a"}, tenant: @tenant_provisioned)
      |> Ash.create()

    {:ok, b} =
      CtxNode
      |> Ash.Changeset.for_create(:create, %{name: "b"}, tenant: @tenant_provisioned)
      |> Ash.create()

    # Act under the NEVER-provisioned tenant. CreateEdge resolves the edge write's graph from
    # the acting tenant, so the edge MATCH runs against a missing graph → Postgres
    # `invalid_schema_name` (a genuine %Postgrex.Error{}), landing in create_one's
    # {:error, error} branch. The `since: @secret` value is bound into that failing query.
    assert {:error, %Ash.Error.Invalid{} = err} =
             a
             |> Ash.Changeset.for_update(
               :add_link,
               %{link_id: b.id, since: @secret},
               tenant: @tenant_missing
             )
             |> Ash.update()

    invalid_rel =
      Enum.find(List.wrap(err.errors), &match?(%Ash.Error.Changes.InvalidRelationship{}, &1))

    assert invalid_rel,
           "expected InvalidRelationship carrying the redacted DB error, got: #{inspect(err)}"

    message = Exception.message(err)

    # It IS the redacted DB-error form emitted by redact_db_error/1 (SQLSTATE only), proving we
    # hit the genuine-DB-error branch — not the 0-row branch and not a raw Postgrex surface.
    assert invalid_rel.message =~ "database error (",
           "expected the redacted `database error (<code>)` form, got: #{invalid_rel.message}"

    # And it leaks nothing: no property value, no source/destination PK, no raw driver content.
    refute message =~ @secret, "property value leaked into the surfaced error: #{message}"
    refute message =~ b.id, "destination PK leaked into the surfaced error: #{message}"
    refute message =~ a.id, "source PK leaked into the surfaced error: #{message}"
    refute message =~ "Postgrex", "raw Postgrex surfaced in the error: #{message}"
    refute message =~ "DETAIL", "a value-bearing DETAIL line surfaced in the error: #{message}"
  end
end
