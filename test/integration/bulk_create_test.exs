defmodule AshAge.Integration.BulkCreateTest do
  @moduledoc """
  Live blast-radius proof of T9's `bulk_create/3` (commit 9b526c1) — the commit
  that flipped `can?(:bulk_create)` to true for EVERY resource and routes
  `Ash.bulk_create` through a single `UNWIND $rows AS row CREATE ...` per key-set
  group. Each scenario exercises a distinct T9 claim against the running AGE DB:

    1. Cross-GROUP reassembly — 20 inputs INTERLEAVED across two key-set groups
       (an optional `note` present on even idx, absent on odd), so each group
       holds a non-contiguous out-of-order subset of 1..20. With `sorted?: true`
       the records come back in full input order ONLY IF the `bulk_create_index`
       stamping (`decode_bulk_records/3` + `BulkHelpers.put_metadata/2`) maps
       each returned vertex to its originating changeset. A single-key-set batch
       would be vacuous (Ash pre-sorts one group regardless of the stamp).
    2. Binary round-trip — a `:binary` attribute survives the `UNWIND $rows`
       param nesting with its `$age64$` tag intact (byte-equality on read-back).
    3. Sparse keys — rows that omit an optional attribute store NO property for
       it (not an explicit `null`), proving key-set grouping avoids null-fill.
    4. `:context` tenancy — a provisioned-tenant bulk lands in that tenant's
       graph; a nil-`:context`-tenant bulk FAILS CLOSED (error + zero rows
       anywhere), mirroring single-create's `write_graph/2` fail-closed path.
    5. Backward-compat — a plain (no-edge, non-multitenant) resource still
       bulk-creates and returns records, proving the `can?` flip didn't break
       the vanilla path.

  A genuine failure here (out-of-order records, binary corruption, null-fill,
  tenancy leak) is a REAL T9 defect — the assertions are NOT to be weakened.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.Type.Agtype
  alias Ecto.Adapters.SQL

  # ------------------------------------------------------------------
  # Resources
  # ------------------------------------------------------------------

  # Order + sparse-key resource: an :integer idx and an OPTIONAL :string note.
  defmodule Item do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_bulk_item)
      repo(AshAge.TestRepo)
      label(:Item)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:idx, :integer, public?: true)
      attribute(:note, :string, public?: true)
    end

    actions do
      default_accept([:idx, :note])
      defaults([:read, :create])
    end
  end

  # Binary round-trip resource.
  defmodule Blob do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_bulk_blob)
      repo(AshAge.TestRepo)
      label(:Blob)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tag, :integer, public?: true)
      attribute(:payload, :binary, public?: true)
    end

    actions do
      default_accept([:tag, :payload])
      defaults([:read, :create])
    end
  end

  # :context multitenant resource.
  defmodule Doc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_bulk_ctx_base)
      repo(AshAge.TestRepo)
      label(:Doc)
    end

    multitenancy do
      strategy(:context)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
    end

    actions do
      default_accept([:title])
      defaults([:read, :create])
    end
  end

  # Backward-compat: plain, no-multitenancy resource.
  defmodule Plain do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_bulk_plain)
      repo(AshAge.TestRepo)
      label(:Plain)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create])
    end
  end

  @tenant_a "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  # ------------------------------------------------------------------
  # :context tenant-graph teardown. Registered at `setup_all` scope (NOT the
  # per-test `setup`), exactly as multitenancy_context_test.exs: `drop_graph`
  # needs an ACCESS EXCLUSIVE lock the still-open per-test Sandbox owner
  # transaction would hold, so the drop is deferred until every per-test owner
  # transaction is gone. Graph DDL is not rolled back by the Sandbox, so the
  # unboxed drop is what cleans up.
  # ------------------------------------------------------------------
  setup_all do
    graph_a = AshAge.tenant_graph(Doc, @tenant_a)

    on_exit(fn ->
      SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
        SQL.query!(AshAge.TestRepo, "SELECT ag_catalog.drop_graph('#{graph_a}', true)", [])
      end)
    end)

    :ok
  end

  # ------------------------------------------------------------------
  # Scenario 1: cross-GROUP reassembly via bulk_create_index
  # ------------------------------------------------------------------
  # This scenario must genuinely EXERCISE T9's `bulk_create_index` stamping — the
  # plan-drift correction whose whole point is that records are mapped back to
  # changesets by that stamp, NOT by positional order. A single-key-set batch is
  # VACUOUS for this: all rows land in one UNWIND group, Ash pre-orders the batch
  # by index before dispatch, and `sorted?: true` is a stable sort, so records
  # come back in `idx` order no matter what index the layer stamps (a reviewer
  # confirmed a constant-index stamp still passed a single-group test).
  #
  # So the 20 inputs INTERLEAVE two distinct key-sets across `idx`: `note` is
  # PRESENT on even idx and ABSENT on odd idx. `group_bulk_entries/1` splits this
  # into two groups — `{id, idx}` (odds: 1,3,5,…,19) and `{id, idx, note}`
  # (evens: 2,4,6,…,20) — each holding a NON-CONTIGUOUS, out-of-order subset of
  # the 1..20 sequence. With correct per-record `bulk_create_index` stamping the
  # two groups' records reassemble to full 1..20; with a broken (e.g. constant)
  # stamp the cross-group interleave comes back out of order. We do NOT sort the
  # records ourselves — `sorted?: true` + the stamp is the mechanism under test.
  test "bulk_create reassembles records across key-set GROUPS in input order (bulk_create_index)" do
    with_graph(
      "itest_bulk_item",
      fn ->
        inputs =
          for i <- 1..20 do
            if rem(i, 2) == 0, do: %{idx: i, note: "n#{i}"}, else: %{idx: i}
          end

        result =
          Ash.bulk_create(inputs, Item, :create, return_records?: true, sorted?: true)

        assert %Ash.BulkResult{status: :success, records: records} = result
        assert length(records) == 20

        # If cross-group reassembly is broken (e.g. constant bulk_create_index),
        # the two groups' non-contiguous subsets interleave out of order here.
        assert Enum.map(records, & &1.idx) == Enum.to_list(1..20)
      end,
      vlabels: ["Item"]
    )
  end

  # ------------------------------------------------------------------
  # Scenario 2: binary round-trip ($age64$ survives UNWIND $rows nesting)
  # ------------------------------------------------------------------
  test "bulk_create round-trips :binary values byte-for-byte ($age64$ survives $rows)" do
    with_graph(
      "itest_bulk_blob",
      fn ->
        # Distinct, non-UTF-8 byte values — the strong test (a raw UTF-8 string
        # could accidentally round-trip even if the $age64$ tagging were broken).
        payloads = %{
          1 => <<0, 255, 16, 128, 1, 250>>,
          2 => <<255, 0, 171>>,
          3 => <<7, 8, 9, 0, 255>>
        }

        inputs = for tag <- 1..3, do: %{tag: tag, payload: payloads[tag]}

        result = Ash.bulk_create(inputs, Blob, :create, return_records?: true, sorted?: true)
        assert %Ash.BulkResult{status: :success, records: records} = result
        assert length(records) == 3

        # Returned records carry the original bytes back through the Ash decode path.
        for rec <- records do
          assert rec.payload == payloads[rec.tag],
                 "bulk-created binary corrupted on return for tag=#{rec.tag}"
        end

        # Independent read-back through Ash proves the STORED value round-trips.
        for read <- Ash.read!(Blob) do
          assert read.payload == payloads[read.tag],
                 "bulk-created binary corrupted in storage for tag=#{read.tag}"
        end

        # And prove the stored property is the $age64$-tagged form (not raw bytes
        # or an untagged base64) — the tag is what makes the byte-safe round-trip
        # deterministic. Read the raw vertex property via Cypher.
        {:ok, %{rows: rows}} =
          cypher_query("itest_bulk_blob", "MATCH (n:Blob) RETURN n")

        for [vtext] <- rows do
          props = vtext |> Agtype.decode() |> Map.fetch!(:properties)
          stored = Map.fetch!(props, "payload")

          assert is_binary(stored) and String.starts_with?(stored, "$age64$"),
                 "stored :binary property is not $age64$-tagged: #{inspect(stored)}"
        end
      end,
      vlabels: ["Blob"]
    )
  end

  # ------------------------------------------------------------------
  # Scenario 3: sparse keys — omitted optional attr stores NO property
  # ------------------------------------------------------------------
  test "bulk_create with sparse keys stores no property for omitted attrs (no null-fill)" do
    with_graph(
      "itest_bulk_item",
      fn ->
        # Row idx=2 OMITS :note entirely; idx=1 and idx=3 set it. Distinct key-sets
        # ⇒ two UNWIND groups ⇒ row 2 must have no `note` property at all.
        inputs = [
          %{idx: 1, note: "has-note"},
          %{idx: 2},
          %{idx: 3, note: "has-note"}
        ]

        result = Ash.bulk_create(inputs, Item, :create, return_records?: true)
        assert %Ash.BulkResult{status: :success, records: records} = result
        assert length(records) == 3

        # Read each vertex's RAW property map via Cypher and inspect key presence —
        # single-create stores an omitted attr as an ABSENT key, and key-set
        # grouping must match that (never `note: null`).
        {:ok, %{rows: rows}} = cypher_query("itest_bulk_item", "MATCH (n:Item) RETURN n")

        by_idx =
          Map.new(rows, fn [vtext] ->
            props = vtext |> Agtype.decode() |> Map.fetch!(:properties)
            {Map.fetch!(props, "idx"), props}
          end)

        assert Map.has_key?(by_idx[1], "note")
        assert Map.has_key?(by_idx[3], "note")

        refute Map.has_key?(by_idx[2], "note"),
               "sparse row stored a `note` property (null-fill): #{inspect(by_idx[2])}"
      end,
      vlabels: ["Item"]
    )
  end

  # ------------------------------------------------------------------
  # Scenario 4a: :context bulk lands in the provisioned tenant graph
  # ------------------------------------------------------------------
  test "bulk_create under a :context tenant lands rows in that tenant's graph" do
    graph_a = AshAge.tenant_graph(Doc, @tenant_a)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      :ok = AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_a, vlabels: ["Doc"])
    end)

    inputs = for i <- 1..3, do: %{title: "t#{i}"}

    result =
      Ash.bulk_create(inputs, Doc, :create, return_records?: true, tenant: @tenant_a)

    assert %Ash.BulkResult{status: :success, records: records} = result
    assert length(records) == 3

    # Rows are readable through the tenant.
    assert {:ok, read} = Doc |> Ash.Query.for_read(:read) |> Ash.read(tenant: @tenant_a)
    assert Enum.map(read, & &1.title) |> Enum.sort() == ["t1", "t2", "t3"]

    # Independent proof the vertices physically live in the TENANT graph. This
    # raw Cypher targets `graph_a` BY NAME (not via Ash's read path), yet runs on
    # the SAME Sandbox connection the bulk write used — an `unboxed_run` here
    # would check out a fresh connection that cannot see the sandbox
    # transaction's rows and would spuriously read 0.
    {:ok, %{rows: [[count]]}} = cypher_query(graph_a, "MATCH (n:Doc) RETURN count(n)")
    assert Agtype.decode(count) == 3
  end

  # ------------------------------------------------------------------
  # Scenario 4b: nil-:context-tenant bulk FAILS CLOSED (error + zero rows)
  # ------------------------------------------------------------------
  test "bulk_create with a nil :context tenant fails closed and writes nothing" do
    graph_a = AshAge.tenant_graph(Doc, @tenant_a)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      :ok = AshAge.Migration.provision_tenant(AshAge.TestRepo, graph_a, vlabels: ["Doc"])
    end)

    inputs = for i <- 1..3, do: %{title: "leak#{i}"}

    # No tenant ⇒ write_graph/2 returns {:error, :tenant_required} ⇒ CreateFailed.
    # There is no global graph for a :context resource, so this must NOT silently
    # write to a base/wrong graph.
    result = Ash.bulk_create(inputs, Doc, :create, return_records?: true, return_errors?: true)

    refute result.status == :success,
           "nil-:context-tenant bulk did NOT fail closed: #{inspect(result)}"

    # Independently confirm NO rows landed in the tenant graph. Raw Cypher on the
    # SAME Sandbox connection (an `unboxed_run` would read a fresh connection and
    # report 0 vacuously — it could never see a sandboxed leak either). A
    # provisioned tenant graph that stays empty after a fail-closed bulk proves
    # nothing was silently written. (A :context resource has no global/base graph
    # to leak INTO — write_graph/2 rejects nil-tenant before any graph resolves.)
    {:ok, %{rows: [[tenant_count]]}} = cypher_query(graph_a, "MATCH (n:Doc) RETURN count(n)")

    assert Agtype.decode(tenant_count) == 0,
           "nil-tenant bulk leaked #{Agtype.decode(tenant_count)} rows into the tenant graph"
  end

  # ------------------------------------------------------------------
  # Scenario 5: backward-compat — plain resource still bulk-creates
  # ------------------------------------------------------------------
  test "bulk_create on a plain non-multitenant resource works and returns records" do
    with_graph(
      "itest_bulk_plain",
      fn ->
        inputs = for i <- 1..5, do: %{name: "p#{i}"}

        result = Ash.bulk_create(inputs, Plain, :create, return_records?: true, sorted?: true)
        assert %Ash.BulkResult{status: :success, records: records} = result
        assert length(records) == 5
        assert Enum.map(records, & &1.name) == ["p1", "p2", "p3", "p4", "p5"]

        # And the rows are readable back.
        assert {:ok, read} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
        assert length(read) == 5
      end,
      vlabels: ["Plain"]
    )
  end
end
