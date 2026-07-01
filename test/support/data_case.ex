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

  alias AshAge.Cypher.Parameterized
  alias AshAge.Migration
  alias Ecto.Adapters.SQL

  using do
    quote do
      alias AshAge.TestRepo
      import AshAge.DataCase
    end
  end

  setup tags do
    pid = SQL.Sandbox.start_owner!(AshAge.TestRepo, shared: not tags[:async])
    on_exit(fn -> SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Runs `fun` with a freshly created AGE graph (and the given `:vlabels`/`:elabels`),
  dropping the graph afterward. Graph DDL and the work inside `fun` run on a real
  (unboxed) connection because `create_graph` is not cleanly rolled back; the
  `drop_graph` in the `after` is what cleans up.

  The graph name and every label are passed through `AshAge.Migration.validate_identifier!/1`
  before interpolation — the same identifier discipline the library enforces in
  production, so this reusable helper never models an unchecked-interpolation pattern.
  """
  def with_graph(graph, fun, opts \\ []) when is_function(fun, 0) do
    graph = Migration.validate_identifier!(graph)
    vlabels = opts |> Keyword.get(:vlabels, []) |> Enum.map(&Migration.validate_identifier!/1)
    elabels = opts |> Keyword.get(:elabels, []) |> Enum.map(&Migration.validate_identifier!/1)

    SQL.Sandbox.unboxed_run(AshAge.TestRepo, fn ->
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

  @doc """
  Runs a Cypher query through the library's own parameterized builder and returns
  the raw `Ecto.Adapters.SQL.query/3` result — the seam every probe uses.
  """
  def cypher_query(graph, cypher, params \\ %{}) do
    {sql, pg_params} =
      if map_size(params) > 0 do
        Parameterized.build(graph, cypher, params)
      else
        Parameterized.build_static(graph, cypher)
      end

    SQL.query(AshAge.TestRepo, sql, pg_params)
  end

  @doc "Runs a raw SQL statement on the test Repo, returning the Postgrex result."
  def exec(sql, params \\ []) do
    SQL.query!(AshAge.TestRepo, sql, params)
  end
end
