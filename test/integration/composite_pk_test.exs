defmodule AshAge.Integration.CompositePkTest do
  use AshAge.DataCase, async: false
  @moduletag :integration

  defmodule Doc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s2_composite
      repo AshAge.TestRepo
      label :Doc
    end

    attributes do
      attribute :tenant_id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:tenant_id, :id, :name]
      defaults [:read, :destroy]

      create :create do
        accept [:tenant_id, :id, :name]
      end

      update :update do
        accept [:name]
      end
    end
  end

  defmodule Coded do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s2_stringkey
      repo AshAge.TestRepo
      label :Coded
    end

    attributes do
      attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:code, :name]
      defaults [:read, :destroy]

      create :create do
        accept [:code, :name]
      end

      update :update do
        accept [:name]
      end
    end
  end

  defmodule RenamableKey do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s2_renamable_key
      repo AshAge.TestRepo
      label :RenamableKey
    end

    attributes do
      attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:key, :name]
      defaults [:read, :destroy]

      create :create do
        accept [:key, :name]
      end

      update :update do
        accept [:key, :name]
      end
    end
  end

  defmodule BinKey do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph :itest_s7_binkey
      repo AshAge.TestRepo
      label :BinKey
    end

    attributes do
      attribute :key, :binary, primary_key?: true, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      default_accept [:key, :name]
      defaults [:read, :destroy]

      create :create do
        accept [:key, :name]
      end

      update :update do
        accept [:name]
      end
    end
  end

  defp create!(resource, attrs) do
    resource |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()
  end

  test "composite PK: update targets exactly the (tenant_id, id) row, not a same-id sibling" do
    with_graph(
      "itest_s2_composite",
      fn ->
        create!(Doc, %{tenant_id: "t1", id: "shared", name: "a"})
        create!(Doc, %{tenant_id: "t2", id: "shared", name: "b"})

        # A hardcoded `WHERE n.id = $id` match would hit BOTH rows (same id).
        [t1_row] = Enum.filter(Ash.read!(Doc), &(&1.tenant_id == "t1"))

        {:ok, updated} =
          t1_row |> Ash.Changeset.for_update(:update, %{name: "a2"}) |> Ash.update()

        assert updated.name == "a2"

        names = Map.new(Ash.read!(Doc), &{&1.tenant_id, &1.name})
        assert names == %{"t1" => "a2", "t2" => "b"}
      end,
      vlabels: ["Doc"]
    )
  end

  test "composite PK: destroy removes exactly the (tenant_id, id) row (DETACH DELETE preserved)" do
    with_graph(
      "itest_s2_composite",
      fn ->
        create!(Doc, %{tenant_id: "t1", id: "shared", name: "a"})
        create!(Doc, %{tenant_id: "t2", id: "shared", name: "b"})

        [t1_row] = Enum.filter(Ash.read!(Doc), &(&1.tenant_id == "t1"))
        t1_row |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy!()

        assert [%{tenant_id: "t2", name: "b"}] = Ash.read!(Doc)
      end,
      vlabels: ["Doc"]
    )
  end

  test "non-:id single PK: update/destroy match on the actual key name (:code)" do
    with_graph(
      "itest_s2_stringkey",
      fn ->
        row = create!(Coded, %{code: "abc", name: "x"})

        {:ok, updated} = row |> Ash.Changeset.for_update(:update, %{name: "y"}) |> Ash.update()
        assert updated.name == "y"
        assert [%{code: "abc", name: "y"}] = Ash.read!(Coded)

        row |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy!()
        assert [] == Ash.read!(Coded)
      end,
      vlabels: ["Coded"]
    )
  end

  test "update renaming a writable, accepted primary-key attribute matches the ORIGINAL row (not the new value)" do
    with_graph(
      "itest_s2_renamable_key",
      fn ->
        row = create!(RenamableKey, %{key: "old-key", name: "x"})

        # A WHERE clause built from the CHANGED value would match zero rows (the
        # stored row still has "old-key"), surfacing as a spurious StaleRecord.
        {:ok, updated} =
          row
          |> Ash.Changeset.for_update(:update, %{key: "new-key", name: "y"})
          |> Ash.update()

        assert updated.key == "new-key"
        assert updated.name == "y"
        assert [%{key: "new-key", name: "y"}] = Ash.read!(RenamableKey)
      end,
      vlabels: ["RenamableKey"]
    )
  end

  test "update with no changed attributes succeeds as a no-op (no invalid SET cypher)" do
    with_graph(
      "itest_s2_stringkey",
      fn ->
        created = create!(Coded, %{code: "noop", name: "a"})

        assert {:ok, same} =
                 created |> Ash.Changeset.for_update(:update, %{}) |> Ash.update()

        assert same.name == "a"
      end,
      vlabels: ["Coded"]
    )
  end

  test "update matching multiple rows (duplicate PK in graph) fails closed, never a raise" do
    with_graph(
      "itest_s2_stringkey",
      fn ->
        # AGE enforces no PK uniqueness — duplicate-keyed vertices are creatable
        # outside Ash. The update WHERE then matches 2 rows; that must surface
        # as a clean value-free error, not a FunctionClauseError crossing the
        # data-layer callback boundary.
        cypher_query("itest_s2_stringkey", "CREATE (:Coded {code: 'collide-k7', name: 'a'})")
        cypher_query("itest_s2_stringkey", "CREATE (:Coded {code: 'collide-k7', name: 'b'})")

        [record | _] = Ash.read!(Coded)

        assert {:error, error} =
                 record |> Ash.Changeset.for_update(:update, %{name: "c"}) |> Ash.update()

        message = Exception.message(error)
        assert message =~ "matched"
        refute message =~ "collide-k7"
      end,
      vlabels: ["Coded"]
    )
  end

  test "binary PK: create/read/update/destroy round-trip (S7 match-param encoding)" do
    key = <<0, 255, 3, 128>>

    with_graph(
      "itest_s7_binkey",
      fn ->
        {:ok, created} =
          BinKey |> Ash.Changeset.for_create(:create, %{key: key, name: "a"}) |> Ash.create()

        assert created.key == key

        # update matches the stored (tagged) form of the binary PK
        {:ok, updated} =
          created |> Ash.Changeset.for_update(:update, %{name: "b"}) |> Ash.update()

        assert updated.name == "b"

        # destroy matches too, and a re-destroy is StaleRecord with a REDACTED filter
        assert :ok = updated |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 updated |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()

        stale = Enum.find(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
        assert stale
        message = Exception.message(stale)
        refute message =~ Base.encode64(key)
        refute String.contains?(message, key)
        # A filter carrying the PRE-serialization raw PK would render via
        # inspect as <<0, 255, ...>> and dodge the two refutes above — pin
        # that leak form too (the edge-path twin already does).
        refute message =~ inspect(key)
        assert message =~ "<redacted>"
      end,
      vlabels: ["BinKey"]
    )
  end
end
