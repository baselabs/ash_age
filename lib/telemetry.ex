defmodule AshAge.Telemetry do
  @moduledoc false
  # Value-free span wrapper for ash_age data-layer operations. Owns the metadata
  # allowlist — the single enforcement point for the R7 invariant "no row-level
  # or tenant-derived value in telemetry". A call site that tries to emit an
  # off-allowlist key (e.g. a tenant-derived `graph`) fails loudly here rather
  # than silently shipping tenant identity into span metadata. Level 0: imports
  # nothing project-internal.

  @allowed_meta_keys ~w(resource multitenancy tenant? stale? properties?
                        direction row_count batch_size group_count
                        destination_count depth result)a

  @doc "The permitted `:start`/`:stop` metadata keys (the R7 allowlist guard)."
  @spec allowed_meta_keys() :: [atom()]
  def allowed_meta_keys, do: @allowed_meta_keys

  @doc """
  Runs `fun` inside `:telemetry.span([:ash_age, op], start_meta, ...)`. `fun`
  returns `{result, stop_meta}`; this returns `result`. Every `start_meta` and
  `stop_meta` key MUST be in `allowed_meta_keys/0` or an ArgumentError is raised.
  """
  @spec span(atom(), map(), (-> {term(), map()})) :: term()
  def span(op, start_meta, fun) when is_atom(op) and is_map(start_meta) and is_function(fun, 0) do
    :telemetry.span([:ash_age, op], validate!(start_meta), fn ->
      {result, stop_meta} = fun.()
      {result, validate!(Map.merge(start_meta, stop_meta))}
    end)
  end

  @doc "Maps a callback return to a value-free `:ok | :error` tag."
  @spec result_tag(term()) :: :ok | :error
  def result_tag({:error, _}), do: :error
  def result_tag(_), do: :ok

  @doc false
  def validate!(meta) when is_map(meta) do
    case Map.keys(meta) -- @allowed_meta_keys do
      [] ->
        meta

      bad ->
        raise ArgumentError,
              "telemetry metadata keys #{inspect(bad)} are not in the value-free allowlist " <>
                "#{inspect(@allowed_meta_keys)} (R7: no row-level or tenant-derived value)"
    end
  end
end
