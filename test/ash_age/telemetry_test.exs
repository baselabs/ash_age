defmodule AshAge.TelemetryTest do
  use ExUnit.Case, async: true

  alias AshAge.Telemetry

  setup do
    ref = make_ref()
    events = [[:ash_age, :probe, :start], [:ash_age, :probe, :stop]]

    :telemetry.attach_many(
      "test-#{inspect(ref)}",
      events,
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-#{inspect(ref)}") end)
    :ok
  end

  test "span/3 emits :start then :stop and returns the fun's result" do
    result =
      Telemetry.span(:probe, %{resource: __MODULE__}, fn ->
        {{:ok, :value}, %{row_count: 3, result: :ok}}
      end)

    assert result == {:ok, :value}
    assert_received {:telemetry, [:ash_age, :probe, :start], %{system_time: _}, start_meta}
    # `:telemetry.span` injects a `telemetry_span_context` ref into handler
    # metadata (telemetry.erl merge_ctx/2) — it is NOT part of ash_age's
    # value-free contract (validate! never sees it; it's added after), so drop it
    # before comparing.
    assert Map.delete(start_meta, :telemetry_span_context) == %{resource: __MODULE__}
    assert_received {:telemetry, [:ash_age, :probe, :stop], %{duration: _}, stop_meta}

    assert Map.delete(stop_meta, :telemetry_span_context) ==
             %{resource: __MODULE__, row_count: 3, result: :ok}
  end

  test "validate! rejects a metadata key outside the allowlist (the R7 guard)" do
    # `graph` is a tenant-derived surrogate and MUST be rejected — this is the
    # single enforcement point for the value-free contract.
    refute :graph in Telemetry.allowed_meta_keys()

    assert_raise ArgumentError, ~r/graph/, fn ->
      Telemetry.span(:probe, %{resource: __MODULE__, graph: :t_acme}, fn ->
        {:ok, %{}}
      end)
    end
  end

  test "result_tag/1 maps error tuples to :error and everything else to :ok" do
    assert Telemetry.result_tag({:error, :boom}) == :error
    assert Telemetry.result_tag({:ok, :rec}) == :ok
    assert Telemetry.result_tag(:ok) == :ok
  end

  test ":depth is an allowed value-free metadata key (traversal bound)" do
    assert :depth in AshAge.Telemetry.allowed_meta_keys()
  end

  test "a :traverse-shaped span with depth metadata does not raise" do
    result =
      AshAge.Telemetry.span(
        :traverse,
        %{resource: __MODULE__, multitenancy: :context, direction: :outgoing},
        fn ->
          {:ok, %{destination_count: 2, row_count: 3, depth: 3, result: :ok}}
        end
      )

    assert result == :ok
  end
end
