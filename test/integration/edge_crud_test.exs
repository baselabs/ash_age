defmodule AshAge.Integration.EdgeCrudTest do
  @moduledoc """
  Live end-to-end characterization of `AshAge.Changes.CreateEdge` /
  `AshAge.Changes.DestroyEdge` driven through real Ash actions against a running
  Apache AGE instance. Proves: edge create + independent traversal read-back,
  string AND non-scalar (binary/datetime) property round-trip, destroy, in-transaction
  atomicity (vertex + edge roll back together on a bad destination), and that a
  stored `:outgoing` edge is reachable from BOTH ends via an undirected `:both`
  match (the S4 contract that binds S5).

  Edges are not first-class Ash-readable yet (S5), so edge properties and edge
  existence are asserted via INDEPENDENT Cypher read-backs through the DataCase
  `cypher_query/3` seam + `Agtype.decode/1` — never off the CREATE statement's own
  RETURN.
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.Type.Agtype

  @binary_tag "$age64$"

  defmodule Person do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s4_edge)
      repo(AshAge.TestRepo)
      label(:Person)

      edge :friend do
        label(:FRIEND)
        destination(Person)
        properties([:since, :photo, :met_at])
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

      # Create a Person AND link a friend in one transaction. Used to prove the
      # vertex rolls back when the edge write fails (atomicity, scenario 3).
      create :create_with_friend do
        accept([:name])
        argument(:friend_id, :uuid)
        change({AshAge.Changes.CreateEdge, edge: :friend, to: :friend_id})
      end

      update :add_friend do
        require_atomic?(false)
        argument(:friend_id, :uuid)
        argument(:since, :string)
        argument(:photo, :binary)
        argument(:met_at, :utc_datetime)
        change({AshAge.Changes.CreateEdge, edge: :friend, to: :friend_id})
      end

      update :remove_friend do
        require_atomic?(false)
        argument(:friend_id, :uuid)
        change({AshAge.Changes.DestroyEdge, edge: :friend, to: :friend_id})
      end
    end
  end

  # `:peer` edge is stored :outgoing (the default) but read undirected. Separate
  # resource/graph so its labels don't collide with Person's :friend edges.
  defmodule Peer do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s4_peer)
      repo(AshAge.TestRepo)
      label(:Peer)

      edge :peer do
        label(:PEER)
        direction(:both)
        destination(Peer)
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many(:peer, __MODULE__, destination_attribute: :id)
    end

    actions do
      defaults([:read])

      create :create do
        accept([:name])
      end

      update :add_peer do
        require_atomic?(false)
        argument(:peer_id, :uuid)
        change({AshAge.Changes.CreateEdge, edge: :peer, to: :peer_id})
      end
    end
  end

  test "add_friend links two Persons; edge is traversable and the `since` property is set" do
    with_graph(
      "itest_s4_edge",
      fn ->
        {:ok, a} = Person |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
        {:ok, b} = Person |> Ash.Changeset.for_create(:create, %{name: "b"}) |> Ash.create()

        {:ok, _} =
          a
          |> Ash.Changeset.for_update(:add_friend, %{friend_id: b.id, since: "2020"})
          |> Ash.update()

        # Independent read-back: (a)-[:FRIEND]->(b) is traversable, proving a real
        # relationship persisted — not just that CREATE returned a row.
        assert {:ok, %{num_rows: 1, rows: [[name]]}} =
                 cypher_query(
                   "itest_s4_edge",
                   "MATCH (:Person {name: 'a'})-[:FRIEND]->(b) RETURN b.name"
                 )

        assert Agtype.decode(name) == "b"

        # The `since` property landed on the edge.
        assert {:ok, %{num_rows: 1, rows: [[since]]}} =
                 cypher_query("itest_s4_edge", "MATCH ()-[e:FRIEND]->() RETURN e.since")

        assert Agtype.decode(since) == "2020"
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end

  test "non-scalar edge properties round-trip: binary is byte-equal, datetime is exact" do
    raw_photo = <<255, 0, 171>>
    met_at = ~U[2021-06-15 08:30:00Z]

    with_graph(
      "itest_s4_edge",
      fn ->
        {:ok, a} = Person |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
        {:ok, b} = Person |> Ash.Changeset.for_create(:create, %{name: "b"}) |> Ash.create()

        {:ok, _} =
          a
          |> Ash.Changeset.for_update(:add_friend, %{
            friend_id: b.id,
            photo: raw_photo,
            met_at: met_at
          })
          |> Ash.update()

        # Read the whole edge back (single agtype column -> %Edge{}) and pull its
        # stored properties. A multi-column `RETURN e.photo, e.met_at` would need a
        # 2-column result definition the DataCase seam doesn't declare.
        assert {:ok, %{num_rows: 1, rows: [[edge_col]]}} =
                 cypher_query("itest_s4_edge", "MATCH ()-[e:FRIEND]->() RETURN e")

        %AshAge.Type.Edge{properties: props} = Agtype.decode(edge_col)

        # Binary: the `$age64$` tag survived storage (a raw-bytes store would corrupt
        # or fail Jason.encode!), and the bytes come back byte-equal.
        assert @binary_tag <> b64 = props["photo"]
        assert Base.decode64!(b64) == raw_photo

        # Datetime: stored ISO8601, parses back to the exact instant.
        assert {:ok, decoded, 0} = DateTime.from_iso8601(props["met_at"])
        assert DateTime.compare(decoded, met_at) == :eq
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end

  test "remove_friend deletes the edge; read-back returns 0 rows" do
    with_graph(
      "itest_s4_edge",
      fn ->
        {:ok, a} = Person |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
        {:ok, b} = Person |> Ash.Changeset.for_create(:create, %{name: "b"}) |> Ash.create()

        {:ok, a} =
          a
          |> Ash.Changeset.for_update(:add_friend, %{friend_id: b.id, since: "2020"})
          |> Ash.update()

        assert {:ok, %{num_rows: 1}} =
                 cypher_query("itest_s4_edge", "MATCH ()-[e:FRIEND]->() RETURN e")

        {:ok, _} =
          a
          |> Ash.Changeset.for_update(:remove_friend, %{friend_id: b.id})
          |> Ash.update()

        assert {:ok, %{num_rows: 0}} =
                 cypher_query("itest_s4_edge", "MATCH ()-[e:FRIEND]->() RETURN e")
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end

  test "atomicity: add_friend to a non-existent friend errors and leaves no edge" do
    with_graph(
      "itest_s4_edge",
      fn ->
        {:ok, a} = Person |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
        ghost = Ash.UUID.generate()

        assert {:error, %Ash.Error.Invalid{} = err} =
                 a
                 |> Ash.Changeset.for_update(:add_friend, %{friend_id: ghost})
                 |> Ash.update()

        assert Enum.any?(
                 List.wrap(err.errors),
                 &match?(%Ash.Error.Changes.InvalidRelationship{}, &1)
               ),
               "expected InvalidRelationship for a 0-row edge write, got: #{inspect(err)}"

        # No partial state: the acting Person's edges are empty.
        assert {:ok, %{num_rows: 0}} =
                 cypher_query(
                   "itest_s4_edge",
                   "MATCH (:Person {name: 'a'})-[e:FRIEND]->() RETURN e"
                 )

        # The Person itself is untouched (the vertex predated the failing action).
        assert {:ok, %{num_rows: 1}} =
                 cypher_query("itest_s4_edge", "MATCH (n:Person {name: 'a'}) RETURN n")
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end

  test "atomicity: create_with_friend to a non-existent friend rolls the vertex back" do
    with_graph(
      "itest_s4_edge",
      fn ->
        ghost = Ash.UUID.generate()

        assert {:error, %Ash.Error.Invalid{} = err} =
                 Person
                 |> Ash.Changeset.for_create(:create_with_friend, %{name: "x", friend_id: ghost})
                 |> Ash.create()

        assert Enum.any?(
                 List.wrap(err.errors),
                 &match?(%Ash.Error.Changes.InvalidRelationship{}, &1)
               ),
               "expected InvalidRelationship for a 0-row edge write, got: #{inspect(err)}"

        # The whole create rolled back: the vertex is absent (edge write failed inside
        # the same transaction, so Ash unwound the CREATE too).
        assert {:ok, %{num_rows: 0}} =
                 cypher_query("itest_s4_edge", "MATCH (n:Person {name: 'x'}) RETURN n")
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end

  defmodule BinDoc do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s7_binedge)
      repo(AshAge.TestRepo)
      label(:BinDoc)

      edge :refs do
        label(:BINREF)
        destination(__MODULE__)
      end
    end

    attributes do
      attribute(:key, :binary, primary_key?: true, allow_nil?: false, public?: true)
    end

    relationships do
      has_many(:refs, __MODULE__, source_attribute: :key, destination_attribute: :key)
    end

    actions do
      default_accept([:key])
      defaults([:read, :destroy])

      create :create do
        accept([:key])
        argument(:to, {:array, :binary})
        change({AshAge.Changes.CreateEdge, edge: :refs, to: :to})
      end

      update :unlink do
        require_atomic?(false)
        argument(:to, {:array, :binary})
        change({AshAge.Changes.DestroyEdge, edge: :refs, to: :to})
      end
    end
  end

  test "binary-PK endpoints: edge create + destroy match the stored tagged form (S7)" do
    a = <<0, 255, 20>>
    b = <<0, 255, 21>>

    with_graph(
      "itest_s7_binedge",
      fn ->
        {:ok, _} = BinDoc |> Ash.Changeset.for_create(:create, %{key: b}) |> Ash.create()

        {:ok, src} =
          BinDoc |> Ash.Changeset.for_create(:create, %{key: a, to: [b]}) |> Ash.create()

        # edge exists: destroy it; a second destroy is StaleRecord whose
        # message leaks neither endpoint's bytes
        {:ok, _} = src |> Ash.Changeset.for_update(:unlink, %{to: [b]}) |> Ash.update()

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 src |> Ash.Changeset.for_update(:unlink, %{to: [b]}) |> Ash.update()

        stale = Enum.find(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
        assert stale
        message = Exception.message(stale)
        refute String.contains?(message, a)
        refute String.contains?(message, b)
        refute message =~ Base.encode64(b)
        # The forms an un-redacted filter would ACTUALLY leak at this call
        # site: src_key arrives tagged (contains Base.encode64(a)) and dst
        # arrives raw, rendered via inspect/1 into StaleRecord's message.
        refute message =~ Base.encode64(a)
        refute message =~ inspect(b)
        assert message =~ "<redacted>"
      end,
      vlabels: ["BinDoc"],
      elabels: ["BINREF"]
    )
  end

  test ":both edge stored outgoing is reachable from both ends via undirected match" do
    with_graph(
      "itest_s4_peer",
      fn ->
        {:ok, a} = Peer |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create()
        {:ok, b} = Peer |> Ash.Changeset.for_create(:create, %{name: "b"}) |> Ash.create()

        {:ok, _} =
          a
          |> Ash.Changeset.for_update(:add_peer, %{peer_id: b.id})
          |> Ash.update()

        # From a's end, undirected match finds b.
        assert {:ok, %{num_rows: 1, rows: [[from_a]]}} =
                 cypher_query(
                   "itest_s4_peer",
                   "MATCH (a:Peer {name: 'a'})-[:PEER]-(x) RETURN x.name"
                 )

        assert Agtype.decode(from_a) == "b"

        # From b's end, the SAME stored :outgoing edge is reachable undirected — the
        # S4 contract S5 relies on.
        assert {:ok, %{num_rows: 1, rows: [[from_b]]}} =
                 cypher_query(
                   "itest_s4_peer",
                   "MATCH (b:Peer {name: 'b'})-[:PEER]-(x) RETURN x.name"
                 )

        assert Agtype.decode(from_b) == "a"
      end,
      vlabels: ["Peer"],
      elabels: ["PEER"]
    )
  end
end
