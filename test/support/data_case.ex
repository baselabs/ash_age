defmodule AshAge.DataCase do
  @moduledoc """
  Test case for live-AGE integration tests. Requires AGE_DATABASE_URL and a
  running Apache AGE database. Excluded from the default `mix test` run via the
  `:integration` tag unless AGE_DATABASE_URL is set (see test_helper.exs).

  AGE graph/label creation is DDL and is NOT rolled back by the Sandbox
  transaction, so `with_graph/3` creates each test's graph on a real (unboxed)
  connection and drops it afterward — isolation comes from the unique graph name
  plus `drop_graph`, not from transactional rollback.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias AshAge.TestRepo
      import AshAge.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshAge.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Runs `fun` with a freshly created AGE graph (and the given vertex/edge labels),
  dropping the graph afterward. Graph DDL and the work inside `fun` run on a real
  (unboxed) connection because `create_graph` is not cleanly rolled back; the
  `drop_graph` in the `after` is what cleans up.
  """
  def with_graph(graph, opts \\ [], fun) do
    vlabels = Keyword.get(opts, :vlabels, [])
    elabels = Keyword.get(opts, :elabels, [])

    Ecto.Adapters.SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
      exec(~s|SELECT ag_catalog.create_graph('#{graph}')|)
      Enum.each(vlabels, &exec(~s|SELECT ag_catalog.create_vlabel('#{graph}', '#{&1}')|))
      Enum.each(elabels, &exec(~s|SELECT ag_catalog.create_elabel('#{graph}', '#{&1}')|))

      try do
        fun.()
      after
        exec(~s|SELECT ag_catalog.drop_graph('#{graph}', true)|)
      end
    end)
  end

  @doc "Runs a raw SQL statement on the test Repo, returning the Postgrex result."
  def exec(sql, params \\ []) do
    Ecto.Adapters.SQL.query!(AshAge.TestRepo, sql, params)
  end
end
