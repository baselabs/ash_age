defmodule AshAge.Integration.AtomicUpdateTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  alias Ash.Query.Operator.Basic.{Minus, Plus, Times}
  alias Ash.Query.Ref

  defp ref(name), do: %Ref{attribute: %{name: name}, relationship_path: []}
  defp plus(n), do: %Plus{left: ref(:count), right: n}
  defp minus(n), do: %Minus{left: ref(:count), right: n}
  defp times(n), do: %Times{left: ref(:count), right: n}

  # A plain resource for atomic-update-over-per-record-update (Tripwires #5, #7).
  # `:update_query` is still false at this slice (Task 4 adds it), so Ash falls
  # back to per-record update/2 — which now carries atomics via atomic_set_clauses
  # (closing the S7 silent-drop gap, D-rev8). The resource name and graph carry
  # the slice tag so graph isolation is unique.
  defmodule Counter do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_atomic_update
      repo AshAge.TestRepo
      label :Counter
    end

    attributes do
      uuid_primary_key :id
      attribute :count, :integer, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:count, :name]
      defaults [:read, update: :*, create: :*]
    end
  end

  # A resource whose attribute name is a Cypher keyword (`:count` is also the
  # resource's integer attr) — proves backtick-quoting on the SET target. The
  # probe D-row showed bare n.count mis-parses (count() aggregate collision).
  defmodule KeywordAttr do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_atomic_kwattr
      repo AshAge.TestRepo
      label :KeywordAttr
    end

    attributes do
      uuid_primary_key :id
      # `count` collides with Cypher's count() aggregate keyword.
      attribute :count, :integer, allow_nil?: false, public?: true
    end

    actions do
      default_accept [:count]
      defaults [:read, update: :*, create: :*]
    end
  end

  describe "atomic updates (per-record update/2 path)" do
    test "atomic increment applies (Tripwire #5 — not silently dropped)" do
      with_graph(:itest_atomic_update, fn ->
        c = Ash.create!(Counter, %{count: 10, name: "a"})

        updated =
          Ash.Changeset.for_update(c, :update)
          |> Ash.Changeset.atomic_update(:count, plus(1))
          |> Ash.update!()

        assert updated.count == 11
      end)
    end

    test "atomic decrement and multiply" do
      with_graph(:itest_atomic_update, fn ->
        c = Ash.create!(Counter, %{count: 20, name: "a"})

        dec =
          Ash.Changeset.for_update(c, :update)
          |> Ash.Changeset.atomic_update(:count, minus(5))
          |> Ash.update!()

        assert dec.count == 15

        mul =
          Ash.Changeset.for_update(dec, :update)
          |> Ash.Changeset.atomic_update(:count, times(2))
          |> Ash.update!()

        assert mul.count == 30
      end)
    end

    test "atomic + plain attribute set together (multi-property SET)" do
      with_graph(:itest_atomic_update, fn ->
        c = Ash.create!(Counter, %{count: 5, name: "old"})

        updated =
          Ash.Changeset.for_update(c, :update)
          |> Ash.Changeset.change_attribute(:name, "new")
          |> Ash.Changeset.atomic_update(:count, plus(1))
          |> Ash.update!()

        assert updated.count == 6
        assert updated.name == "new"
      end)
    end

    test "atomics win over a same-attr plain change (Tripwire #7 — D10, last-wins)" do
      # change_attribute(:count, 99) + atomic_update(:count, count+1): both reach
      # update/2 (probe: atomics=[count+1], attributes=%{count:99}); Cypher SET
      # emits plain AFTER... no — atomics AFTER plain, last-wins → count = old+1.
      with_graph(:itest_atomic_update, fn ->
        c = Ash.create!(Counter, %{count: 10, name: "a"})

        updated =
          Ash.Changeset.for_update(c, :update)
          |> Ash.Changeset.change_attribute(:count, 99)
          |> Ash.Changeset.atomic_update(:count, plus(1))
          |> Ash.update!()

        # old=10; atomics-last-wins → 10+1 = 11 (NOT 99).
        assert updated.count == 11
      end)
    end
  end

  describe "keyword-named attribute (Tripwire #3 — backtick-quoting)" do
    test "atomic increment on an attr named :count (Cypher keyword)" do
      with_graph(:itest_atomic_kwattr, fn ->
        k = Ash.create!(KeywordAttr, %{count: 7})

        updated =
          Ash.Changeset.for_update(k, :update)
          |> Ash.Changeset.atomic_update(:count, plus(1))
          |> Ash.update!()

        assert updated.count == 8
      end)
    end
  end

  describe "upsert rejects atomics (Tripwire #8 — D-rev8)" do
    defmodule UpsertCounter do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph :itest_atomic_upsert
        repo AshAge.TestRepo
        label :UpsertCounter
      end

      identities do
        identity :name, [:name]
      end

      attributes do
        uuid_primary_key :id
        attribute :name, :string, allow_nil?: false, public?: true
        attribute :count, :integer, public?: true
      end

      actions do
        default_accept [:name, :count]
        defaults [:read]

        create :upsert do
          upsert? true
          upsert_identity :name
        end
      end
    end

    test "an upsert action carrying atomics fails closed (not a silent drop or a race)" do
      with_graph(:itest_atomic_upsert, fn ->
        assert {:error, _} =
                 Ash.Changeset.for_create(UpsertCounter, :upsert, %{name: "x", count: 1})
                 |> Ash.Changeset.atomic_update(:count, plus(1))
                 |> Ash.create()
      end)
    end
  end

  # A :attribute multitenant resource for the bulk (update_query) path. The atomic
  # bulk dispatch (Ash's do_atomic_update) requires the tenant on the QUERY — the
  # documented Ash contract for bulk ops (set_tenant before the action; the
  # stream/per-record path tolerates opts-tenant, the atomic path does not).
  defmodule TenantCounter do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    age do
      graph :itest_atomic_bulk_tenant
      repo AshAge.TestRepo
      label :TenantCounter
    end

    attributes do
      attribute :org_id, :string, primary_key?: true, allow_nil?: false, public?: true
      uuid_primary_key :id
      attribute :count, :integer, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:count, :name]
      defaults [:read, :create, update: :*]
    end
  end

  describe "bulk update (update_query/4 path)" do
    test "atomic increment over a filtered set applies to every match (Tripwire #9 — bulk path)" do
      # Exercises update_query/4 (the callback the WIP's per-record tests never
      # reached). 5 rows, 3 match `name == "go"`; all 3 increment; the 2 others
      # are untouched.
      with_graph(:itest_atomic_update, fn ->
        for _ <- 1..3, do: {:ok, _} = Ash.create(Counter, %{count: 10, name: "go"})
        for _ <- 1..2, do: {:ok, _} = Ash.create(Counter, %{count: 10, name: "stay"})

        query = Counter |> Ash.Query.for_read(:read) |> Ash.Query.filter(name == "go")

        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.bulk_update(query, :update, %{}, atomic_update: %{count: plus(1)})

        go = Counter |> Ash.Query.for_read(:read) |> Ash.Query.filter(name == "go") |> Ash.read!()
        stay = Counter |> Ash.Query.for_read(:read) |> Ash.Query.filter(name == "stay") |> Ash.read!()

        assert length(go) == 3
        assert Enum.all?(go, &(&1.count == 11))
        assert Enum.all?(stay, &(&1.count == 10))
      end)
    end

    test "bulk update on a Cypher-keyword filter attr (count) — filter + SET backtick together" do
      # Regression for the keyword-attr collision: filtering on `count` (a Cypher
      # keyword) emits `n.`count`` in WHERE; the SET side emits `n.`count`` too.
      # Bare `n.count` in either place is a syntax error in AGE.
      with_graph(:itest_atomic_kwattr, fn ->
        {:ok, _} = Ash.create(KeywordAttr, %{count: 1})
        {:ok, _} = Ash.create(KeywordAttr, %{count: 1})
        {:ok, _} = Ash.create(KeywordAttr, %{count: 9})

        query = KeywordAttr |> Ash.Query.for_read(:read) |> Ash.Query.filter(count == 1)

        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.bulk_update(query, :update, %{}, atomic_update: %{count: plus(1)})

        ones = KeywordAttr |> Ash.Query.for_read(:read) |> Ash.Query.filter(count == 2) |> Ash.read!()
        assert length(ones) == 2
      end)
    end

    test "bulk update under tenant A increments only A's rows; B untouched (F5-equivalent)" do
      with_graph(:itest_atomic_bulk_tenant, fn ->
        for _ <- 1..3, do: {:ok, _} = Ash.create(TenantCounter, %{count: 1, name: "go"}, tenant: "org-a")
        {:ok, _} = Ash.create(TenantCounter, %{count: 1, name: "go"}, tenant: "org-b")
        {:ok, b_other} = Ash.create(TenantCounter, %{count: 1, name: "go"}, tenant: "org-b")

        # Tenant on the QUERY (Ash bulk contract). A buggy unscoped SET would bump
        # B's `name == "go"` row too.
        query =
          TenantCounter
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(name == "go")
          |> Ash.Query.set_tenant("org-a")

        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.bulk_update(query, :update, %{},
                   tenant: "org-a",
                   atomic_update: %{count: plus(1)}
                 )

        a_rows = Ash.read!(TenantCounter, tenant: "org-a")
        assert length(a_rows) == 3
        assert Enum.all?(a_rows, &(&1.count == 2))

        # B: every row still count == 1 (the matched-go row AND the other).
        b_rows = Ash.read!(TenantCounter, tenant: "org-b")
        assert length(b_rows) == 2
        assert Enum.all?(b_rows, &(&1.count == 1))
        assert b_other.id in Enum.map(b_rows, & &1.id)
      end)
    end

    test "0-match bulk update returns success (not an error)" do
      with_graph(:itest_atomic_update, fn ->
        {:ok, _} = Ash.create(Counter, %{count: 5, name: "x"})

        query = Counter |> Ash.Query.for_read(:read) |> Ash.Query.filter(name == "missing")

        assert %Ash.BulkResult{status: :success, error_count: 0} =
                 Ash.bulk_update(query, :update, %{}, atomic_update: %{count: plus(1)})

        # Unchanged.
        assert hd(Ash.read!(Counter)).count == 5
      end)
    end

    test "return_records? returns the updated records" do
      with_graph(:itest_atomic_update, fn ->
        {:ok, _} = Ash.create(Counter, %{count: 1, name: "go"})
        {:ok, _} = Ash.create(Counter, %{count: 1, name: "go"})

        query = Counter |> Ash.Query.for_read(:read) |> Ash.Query.filter(name == "go")

        assert %Ash.BulkResult{status: :success, records: records} =
                 Ash.bulk_update(query, :update, %{},
                   atomic_update: %{count: plus(1)},
                   return_records?: true
                 )

        assert length(records) == 2
        assert Enum.all?(records, &(&1.count == 2))
      end)
    end
  end
end
