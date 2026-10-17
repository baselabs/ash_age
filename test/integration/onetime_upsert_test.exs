defmodule AshAge.Integration.OnetimeUpsertTest do
  @moduledoc """
  Executable proof of the documented pattern "Race-free upserts with
  ash_onetime" (documentation/idempotent-upserts.md).

  ash_age's upsert is a two-statement MATCH-then-CREATE path and AGE has NO
  unique constraint, so concurrent upserts of the same identity can both take
  the CREATE branch. An AGE graph IS PostgreSQL: when the host reserves an
  ash_onetime admission claim in the SAME transaction that performs the graph
  write, PostgreSQL's unique constraint becomes the arbiter AGE lacks — the
  loser's claim insert blocks on the winner's row and returns a typed error
  (or replays after commit), and its graph write never commits.

  This test runs the REAL claim-store DDL (rendered from ash_onetime's own
  migration template — no hand-rolled table) on the same AGE server, then:

  1. races two host-owned transactions on one idempotency key — exactly one
     vertex lands;
  2. replays the completed key — the stored response replays verbatim and no
     new vertex lands;
  3. aborts a transaction AFTER the graph write — the claim AND the vertex
     roll back together (atomicity of the pairing).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.TestRepo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations
  require Ash.Query

  @graph :itest_onetime

  defmodule Item do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_onetime)
      repo(AshAge.TestRepo)
      label(:Item)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, allow_nil?: false, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create])
    end
  end

  setup_all context do
    # The claims/nonce/response DDL, rendered from ash_onetime's own install
    # template and run through the real Ecto.Migrator — zero drift with the
    # shipped schema. DDL is not transactional: run unboxed, drop after.
    dir = Path.join(System.tmp_dir!(), "ash_age_onetime_#{System.unique_integer([:positive])}")
    migrations_dir = Path.join(dir, "migrations")
    File.mkdir_p!(migrations_dir)

    source =
      GenerateMigrations.render(TestRepo,
        hash_partitions: nil,
        partition_start: nil
      )

    File.write!(Path.join(migrations_dir, "20260101000000_install_ash_onetime.exs"), source)

    # DDL + the migrator's internal checkouts cannot run under the sandbox's
    # manual mode: flip the repo to auto for the provisioning phase, back to
    # manual before the per-test owners start.
    Sandbox.mode(TestRepo, :auto)

    Ecto.Migrator.run(TestRepo, migrations_dir, :up, all: true)
    run_sql("SELECT ag_catalog.create_graph('itest_onetime')")
    run_sql("SELECT ag_catalog.create_vlabel('itest_onetime', 'Item')")

    Sandbox.mode(TestRepo, :manual)

    on_exit(fn ->
      Sandbox.mode(TestRepo, :auto)

      run_sql("SELECT ag_catalog.drop_graph('itest_onetime', true)")
      Ecto.Migrator.run(TestRepo, migrations_dir, :down, all: true)

      Sandbox.mode(TestRepo, :manual)
      File.rm_rf!(dir)
    end)

    context
  end

  defp run_sql(sql), do: SQL.query!(TestRepo, sql, [])

  # The documented host pattern: ONE transaction wrapping the admission claim,
  # the graph write, and the claim completion.
  defp create_once(key, name) do
    TestRepo.transaction(fn ->
      case admission_for(key, name) do
        {:execute, admission} ->
          {:ok, item} =
            Item |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(upsert?: true)

          payload = Jason.encode!(%{"id" => item.id, "name" => item.name})
          complete(admission, payload)
          {:ok, item}

        {:replay, bytes} ->
          {:replay, bytes}

        {:error, error} ->
          throw({:admission, error})
      end
    end)
  end

  defp admission_for(key, name) do
    AshOnetime.Transaction.idempotency(TestRepo,
      operation: {__MODULE__, :create_item},
      partition: "global",
      scope: "items",
      key: key,
      fingerprint: :crypto.hash(:sha256, name),
      retention_seconds: 3600,
      codec: "raw"
    )
  end

  defp complete(admission, payload) do
    case AshOnetime.Transaction.complete(admission, payload) do
      :ok -> :ok
      {:ok, _} = ok -> ok
    end
  end

  defp vertex_count(name) do
    {:ok, [%{c: n}]} =
      AshAge.cypher(
        TestRepo,
        @graph,
        "MATCH (n:Item) WHERE n.`name` = $name RETURN count(n) AS c",
        %{"name" => name},
        c: :agtype
      )

    n
  end

  # These tests need REAL connections (the race spawns two concurrent
  # transactions on separate pool connections) — run outside the sandbox's
  # ownership, isolated by the unique graph name and per-test keys.
  defp with_real_connections(fun) do
    Sandbox.mode(TestRepo, :auto)
    fun.()
  after
    Sandbox.mode(TestRepo, :manual)
  end

  test "two racing transactions on one key land exactly one vertex (Postgres arbitrates)" do
    with_real_connections(fn ->
      a = Task.async(fn -> create_once("race-1", "solo") end)
      b = Task.async(fn -> create_once("race-1", "solo") end)
      ra = Task.await(a, 30_000)
      rb = Task.await(b, 30_000)

      # Exactly one executed; the other was refused at admission (processing)
      # or replayed — never a second graph write.
      executed = [ra, rb] |> Enum.count(&match?({:ok, {:ok, _}}, &1))
      assert executed == 1
      other = [ra, rb] |> Enum.reject(&match?({:ok, {:ok, _}}, &1)) |> hd()

      assert match?({:ok, {:replay, _}}, other) or match?({:ok, {:error, _}}, other) or
               match?({:error, _}, other)

      assert vertex_count("solo") == 1
    end)
  end

  test "a replayed key returns the stored response and lands no new vertex" do
    with_real_connections(fn ->
      assert {:ok, {:ok, item}} = create_once("replay-1", "kept")
      assert {:ok, {:replay, bytes}} = create_once("replay-1", "kept")
      assert Jason.decode!(bytes)["id"] == item.id
      assert vertex_count("kept") == 1
    end)
  end

  test "a rollback after the graph write takes the claim AND the vertex with it" do
    with_real_connections(fn ->
      result =
        TestRepo.transaction(fn ->
          {:execute, admission} =
            AshOnetime.Transaction.idempotency(TestRepo,
              operation: {__MODULE__, :create_item},
              partition: "global",
              scope: "items",
              key: "rollback-1",
              fingerprint: :crypto.hash(:sha256, "doomed"),
              retention_seconds: 3600,
              codec: "raw"
            )

          {:ok, _} =
            Item
            |> Ash.Changeset.for_create(:create, %{name: "doomed"})
            |> Ash.create(upsert?: true)

          # The host effect fails AFTER the vertex was written (rollback, not
          # raise, so the transaction RETURNS the reason):
          TestRepo.rollback(:host_effect_failed)
        end)

      assert {:error, :host_effect_failed} = result

      # Both sides are gone: no vertex, and the key is fresh again (a retry
      # executes rather than colliding with a phantom claim).
      assert vertex_count("doomed") == 0

      assert {:ok, {:ok, _}} = create_once("rollback-1", "retry")
      assert vertex_count("retry") == 1
    end)
  end
end
