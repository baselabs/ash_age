defmodule AshAge.Integration.TelemetryTest do
  @moduledoc "Live proof that data-layer ops emit value-free [:ash_age, op] spans."
  use AshAge.DataCase, async: false
  @moduletag :integration

  alias AshAge.Telemetry

  defmodule Thing do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_tel)
      repo(AshAge.TestRepo)
      label(:Thing)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, :create, :update, :destroy])
      default_accept([:name])
    end
  end

  defp attach(ops) do
    handler = "tel-#{inspect(make_ref())}"

    events =
      Enum.flat_map(ops, fn op ->
        [[:ash_age, op, :start], [:ash_age, op, :stop], [:ash_age, op, :exception]]
      end)

    :telemetry.attach_many(
      handler,
      events,
      fn event, meas, meta, _ ->
        send(self(), {:tel, event, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # `:telemetry.span` injects a `telemetry_span_context` ref into handler
  # metadata; not part of ash_age's value-free contract, so drop it first.
  defp assert_value_free(meta) do
    ours = Map.delete(meta, :telemetry_span_context)

    for key <- Map.keys(ours) do
      assert key in Telemetry.allowed_meta_keys(), "leaked telemetry key #{inspect(key)}"
    end

    refute Map.has_key?(ours, :graph)
    refute Map.has_key?(ours, :reason)
  end

  test "create + read + update + destroy emit value-free :start/:stop spans" do
    with_graph(
      "itest_tel",
      fn ->
        attach([:create, :read, :update, :destroy])

        {:ok, thing} = Ash.create(Thing, %{name: "a"})
        assert_received {:tel, [:ash_age, :create, :start], _, s_meta}

        assert Map.delete(s_meta, :telemetry_span_context) == %{
                 resource: Thing,
                 multitenancy: nil
               }

        assert_received {:tel, [:ash_age, :create, :stop], %{duration: _}, meta}
        assert meta.result == :ok
        assert meta.tenant? == false
        assert_value_free(meta)

        {:ok, _} = Ash.read(Thing)
        assert_received {:tel, [:ash_age, :read, :stop], _, read_meta}
        assert read_meta.row_count >= 1
        assert_value_free(read_meta)

        {:ok, _} = thing |> Ash.Changeset.for_update(:update, %{name: "b"}) |> Ash.update()
        assert_received {:tel, [:ash_age, :update, :stop], _, u_meta}
        assert u_meta.result == :ok and u_meta.stale? == false
        assert_value_free(u_meta)

        :ok = thing |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()
        assert_received {:tel, [:ash_age, :destroy, :stop], _, d_meta}
        assert_value_free(d_meta)
      end,
      vlabels: ["Thing"]
    )
  end

  test "a stale update emits result: :error, stale?: true, still value-free" do
    with_graph(
      "itest_tel",
      fn ->
        attach([:update])
        ghost = struct(Thing, id: Ash.UUID.generate(), name: "x", __meta__: %{state: :loaded})

        assert {:error, _} =
                 ghost |> Ash.Changeset.for_update(:update, %{name: "y"}) |> Ash.update()

        assert_received {:tel, [:ash_age, :update, :stop], _, meta}
        assert meta.result == :error and meta.stale? == true
        assert_value_free(meta)
      end,
      vlabels: ["Thing"]
    )
  end

  test "bulk_create emits batch_size/group_count spans, value-free" do
    with_graph(
      "itest_tel",
      fn ->
        attach([:bulk_create])
        rows = [%{name: "a"}, %{name: "b"}, %{name: "c"}]

        assert %Ash.BulkResult{status: :success} =
                 Ash.bulk_create(rows, Thing, :create, return_records?: true)

        assert_received {:tel, [:ash_age, :bulk_create, :stop], _, meta}
        assert meta.batch_size == 3 and meta.group_count == 1 and meta.result == :ok
        assert_value_free(meta)
      end,
      vlabels: ["Thing"]
    )
  end

  defmodule Person do
    use Ash.Resource,
      domain: AshAge.TestDomain,
      validate_domain_inclusion?: false,
      data_layer: AshAge.DataLayer

    age do
      graph(:itest_tel_edge)
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
      has_many(:friend, Person, destination_attribute: :id)
    end

    actions do
      defaults([:read, :create])
      default_accept([:name])

      update :add_friend do
        require_atomic?(false)
        argument(:friend_id, :uuid, allow_nil?: false)
        argument(:since, :string)
        change({AshAge.Changes.CreateEdge, edge: :friend, to: :friend_id})
      end

      update :remove_friend do
        require_atomic?(false)
        argument(:friend_id, :uuid, allow_nil?: false)
        change({AshAge.Changes.DestroyEdge, edge: :friend, to: :friend_id})
      end

      update :bad_edge do
        require_atomic?(false)
        argument(:friend_id, :uuid, allow_nil?: false)
        change({AshAge.Changes.CreateEdge, edge: :nonexistent, to: :friend_id})
      end
    end
  end

  test "create_edge/destroy_edge emit value-free spans; a bad edge emits :exception" do
    with_graph(
      "itest_tel_edge",
      fn ->
        attach([:create_edge, :destroy_edge])
        {:ok, a} = Ash.create(Person, %{name: "a"})
        {:ok, b} = Ash.create(Person, %{name: "b"})

        {:ok, _} =
          a
          |> Ash.Changeset.for_update(:add_friend, %{friend_id: b.id, since: "2026"})
          |> Ash.update()

        assert_received {:tel, [:ash_age, :create_edge, :stop], _, meta}
        assert meta.result == :ok and meta.destination_count == 1
        assert meta.direction == :outgoing and meta.properties? == true
        assert_value_free(meta)

        {:ok, _} =
          a |> Ash.Changeset.for_update(:remove_friend, %{friend_id: b.id}) |> Ash.update()

        assert_received {:tel, [:ash_age, :destroy_edge, :stop], _, d_meta}
        assert d_meta.result == :ok and d_meta.destination_count == 1
        assert_value_free(d_meta)

        # A config-error raise (undeclared edge) inside the span surfaces
        # :exception before the raise propagates. `EdgeCypher.fetch_edge!/2`
        # raises an ArgumentError; Ash wraps an after_action-hook raise in an
        # Ash.Error.Unknown, so the top-level match is on the wrapped error --
        # the value-free :exception event (kind: :error) is what this asserts.
        attach([:create_edge])

        assert_raise Ash.Error.Unknown, fn ->
          a |> Ash.Changeset.for_update(:bad_edge, %{friend_id: b.id}) |> Ash.update()
        end

        assert_received {:tel, [:ash_age, :create_edge, :exception], _, ex_meta}
        assert ex_meta.kind == :error
      end,
      vlabels: ["Person"],
      elabels: ["FRIEND"]
    )
  end
end
