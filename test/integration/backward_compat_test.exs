defmodule AshAge.Integration.BackwardCompatTest do
  @moduledoc """
  A resource with no `multitenancy` block must behave byte-identically to
  pre-S3: writes target `Info.graph/1`, `set_tenant/3` never fires, and CRUD is
  unchanged. Release-gating per spec §2.3.

  S7 rescope: `sensitive` is runtime-inert, so the changed compat surface is
  BINARY-storage attributes, not sensitive-marked resources. Control 1 pins the
  no-change side (non-binary params stay raw, no `$age64$` tag); control 2
  characterizes the conscious C1 capability trade (untagged externally-written
  binary rows: readable verbatim, unmatchable through Ash filters).
  """
  use AshAge.DataCase, async: false
  @moduletag :integration

  require Ash.Query

  alias AshAge.DataLayer.Info
  alias AshAge.Query
  alias AshAge.Query.Filter

  alias Ash.Query.Operator.Eq
  alias Ash.Query.Ref

  defmodule Plain do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s3_plain)
      repo(AshAge.TestRepo)
      label(:Plain)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      default_accept([:name])
      defaults([:read, :create, :update, :destroy])
    end
  end

  test "no-multitenancy resource uses the base graph and full CRUD works" do
    # write_graph resolves the base graph regardless of any tenant.
    assert AshAge.DataLayer.write_graph(Plain, %{to_tenant: "irrelevant"}) ==
             {:ok, :itest_s3_plain}

    with_graph(
      "itest_s3_plain",
      fn ->
        {:ok, p} = Plain |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create()
        assert {:ok, [got]} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
        assert got.id == p.id

        {:ok, p2} = p |> Ash.Changeset.for_update(:update, %{name: "y"}) |> Ash.update()
        assert p2.name == "y"

        :ok = p2 |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()
        assert {:ok, []} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
      end,
      vlabels: ["Plain"]
    )
  end

  test "a resource without rls_guc behaves identically (RLS off = with_rls pass-through)" do
    assert Info.rls_guc(Plain) == nil

    with_graph(
      "itest_s3_plain",
      fn ->
        {:ok, p} = Plain |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create()
        assert {:ok, [got]} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
        assert got.id == p.id

        {:ok, p2} = p |> Ash.Changeset.for_update(:update, %{name: "y"}) |> Ash.update()
        assert p2.name == "y"

        :ok = p2 |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()
        assert {:ok, []} = Plain |> Ash.Query.for_read(:read) |> Ash.read()
      end,
      vlabels: ["Plain"]
    )
  end

  test "destroy of an absent row returns StaleRecord (S3 0-row semantics, reaches plain resources)" do
    with_graph(
      "itest_s3_plain",
      fn ->
        {:ok, p} = Plain |> Ash.Changeset.for_create(:create, %{name: "x"}) |> Ash.create()
        :ok = p |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()

        # Second destroy of the same (now-absent) row matches 0 rows. Pre-S3 this
        # returned :ok unconditionally; S3 returns StaleRecord — the Ash contract
        # signal for a record-based mutation that matched nothing (what the
        # reference ETS data layer and Ash core do). Documented in CHANGELOG.
        assert {:error, err} = p |> Ash.Changeset.for_destroy(:destroy, %{}) |> Ash.destroy()

        assert Enum.any?(
                 List.wrap(Map.get(err, :errors, [err])),
                 &match?(%Ash.Error.Changes.StaleRecord{}, &1)
               ),
               "expected StaleRecord for a 0-row destroy, got: #{inspect(err)}"
      end,
      vlabels: ["Plain"]
    )
  end

  # S7 compat control 1: non-binary attributes produce raw (unencoded) filter
  # params — asserted at the translator seam, the same unit seam filter_test
  # uses, so the claim is byte-level, not inferred. Goes red if the filter ever
  # starts tagging string params.
  test "S7: string filter params carry no $age64$ tag" do
    {:ok, query, clause} =
      Filter.translate(
        %Eq{
          left: %Ref{attribute: %{name: :name, type: Ash.Type.String, constraints: []}},
          right: "x"
        },
        %Query{resource: Plain, graph: :g, label: :Plain, repo: TestRepo, params: %{}}
      )

    assert clause == "n.name = $param1"
    assert query.params == %{"param1" => "x"}
  end

  # S7 compat control 2 (the C1 capability trade, characterized): an untagged
  # binary value written OUTSIDE ash_age is READABLE (verbatim grace in
  # Cast.coerce_value/2) but NOT matchable through Ash filters — the match
  # param is the tagged form. If a future change adds dual-match
  # ($tagged OR $raw), the final assertion goes red and forces that decision
  # to be re-made consciously.
  defmodule LegacyBlob do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_s7_legacy)
      repo(AshAge.TestRepo)
      label(:LegacyBlob)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:payload, :binary, public?: true)
    end

    actions do
      default_accept([:payload])
      defaults([:read, :create])
    end
  end

  test "S7: externally-written untagged binary rows are read-only grace — readable, not matchable" do
    legacy_value = "not-tagged-utf8-safe"

    with_graph(
      "itest_s7_legacy",
      fn ->
        # simulate an external writer: raw property value, no $age64$ tag
        {:ok, _} =
          cypher_query(
            "itest_s7_legacy",
            "CREATE (n:LegacyBlob) SET n.id = $id, n.payload = $payload RETURN n",
            %{"id" => Ash.UUID.generate(), "payload" => legacy_value}
          )

        # READ grace: the row comes back with the value verbatim
        assert {:ok, [row]} = Ash.read(LegacyBlob)
        assert row.payload == legacy_value

        # NOT matchable: the eq param is the tagged form; the stored row is raw
        assert {:ok, []} =
                 LegacyBlob |> Ash.Query.filter(payload == ^legacy_value) |> Ash.read()
      end,
      vlabels: ["LegacyBlob"]
    )
  end
end
