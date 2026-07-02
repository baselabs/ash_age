defmodule AshAge do
  @moduledoc """
  Ash Framework DataLayer for Apache AGE graph database.

  ## Setup

  ### 1. Register Postgrex Types

  Create a Postgrex types module so AGE's `agtype` is understood by Ecto:

      # `Postgrex.Types.define/3` defines the module itself — call it at the top
      # level of the file (no `defmodule` wrapper of the same name).
      Postgrex.Types.define(
        MyApp.PostgrexTypes,
        [AshAge.Postgrex.AgtypeExtension] ++ Ecto.Adapters.Postgres.extensions(),
        []
      )

  Then reference it in your Repo config:

      config :my_app, MyApp.Repo,
        types: MyApp.PostgrexTypes

  ### 2. Configure the Repo

  Add the AGE session hook so each connection sets the search path and loads AGE:

      config :my_app, MyApp.Repo,
        after_connect: {AshAge.Session, :setup, []},
        types: MyApp.PostgrexTypes

  ### 3. Create an AGE Migration

  Generate a migration with `mix ash_age.gen.migration`, or write one manually:

      defmodule MyApp.Repo.Migrations.CreateAgeGraph do
        use Ecto.Migration
        import AshAge.Migration

        def up do
          create_age_graph("my_graph")
          create_vertex_label("my_graph", "Entity")
        end

        def down do
          drop_age_graph("my_graph")
        end
      end

  ### 4. Define Ash Resources

      defmodule MyApp.Entity do
        use Ash.Resource,
          domain: MyApp.Domain,
          data_layer: AshAge.DataLayer

        age do
          graph :my_graph
          repo MyApp.Repo
          label :Entity
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string, allow_nil?: false
          attribute :properties, :map, default: %{}
        end

        actions do
          defaults [:read, :create, :update, :destroy]
        end
      end

  ## Mix Tasks

  - `mix ash_age.install` — Print setup instructions
  - `mix ash_age.gen.migration` — Generate an AGE migration
  - `mix ash_age.verify` — Verify AGE database configuration

  ## Modules

  - `AshAge.DataLayer` — The Ash DataLayer implementation
  - `AshAge.Session` — Connection session setup
  - `AshAge.Migration` — Migration helpers
  - `AshAge.Graph` — Graph management utilities
  """

  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer
  alias AshAge.Errors.QueryFailed
  alias AshAge.Telemetry
  alias AshAge.Type.Agtype
  alias Ecto.Adapters.SQL

  @doc """
  Resolves the AGE graph name for a `:context`-multitenant `resource` and `tenant`.

  Host applications call this to derive the graph name to provision (via
  `AshAge.Migration.provision_tenant/3`), guaranteeing the provisioned name matches
  the one ash_age resolves at query time. Delegates to `AshAge.Multitenancy.graph_name/2`.
  """
  @spec tenant_graph(Ash.Resource.t(), term()) :: String.t()
  def tenant_graph(resource, tenant), do: AshAge.Multitenancy.graph_name(resource, tenant)

  @doc """
  Runs arbitrary parameterized Cypher against `graph` on `repo`, returning decoded
  results — the escape hatch for graph queries Ash's DSL cannot express.

      AshAge.cypher(MyApp.Repo, "my_graph",
        "MATCH (n:Person)-[:KNOWS*1..2]->(m) WHERE n.id = $id RETURN m",
        %{"id" => person_id}, [{:m, :agtype}])
      #=> {:ok, [%{m: %AshAge.Type.Vertex{...}}, ...]}

  ## Contract

  - **Values reach AGE only as `$` parameters** (`params`); the `cypher` body is
    yours to write. The `graph` name is `validate_identifier!`-checked; a `$$`
    break-out in the body is rejected.
  - **Return:** `{:ok, [row_map]}` where each `row_map` is `%{column_name =>
    decoded}` keyed by the atoms in `return_types`. Each cell decodes to a
    `AshAge.Type.Vertex`/`Edge`/`Path` or a scalar; a bare agtype **aggregate**
    (`collect(n)`, `{k: v}`) is returned as its **raw agtype string** (aggregate
    decoding is out of scope — use Cypher `UNWIND` for collections).
  - **Tenancy is explicit:** the `graph` you pass IS the isolation boundary
    (`:context`). This opens no transaction of its own; for `:attribute` + RLS
    defense-in-depth, wrap the call in `AshAge.with_tenant_rls/4`, which sets the
    tenant GUC (`set_config`) on the same connection.
  """
  @spec cypher(module(), atom() | String.t(), String.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, Exception.t()}
  def cypher(repo, graph, cypher, params \\ %{}, return_types) do
    Telemetry.span(:cypher, %{}, fn ->
      {sql, pg_params} =
        if map_size(params) > 0 do
          Parameterized.build(graph, cypher, params, return_types)
        else
          Parameterized.build_static(graph, cypher, return_types)
        end

      # Column names are constant across the whole result set — compute once,
      # not per row (mirrors the read path's compute-once attribute maps).
      cols = column_names(return_types)

      result =
        case SQL.query(repo, sql, pg_params) do
          {:ok, %{rows: rows}} ->
            {:ok, Enum.map(rows, &decode_row(&1, cols))}

          {:error, error} ->
            {:error,
             QueryFailed.exception(
               query: "AGE raw cypher",
               reason: DataLayer.redact_db_error(error)
             )}
        end

      {result, %{row_count: row_count(result), result: Telemetry.result_tag(result)}}
    end)
  end

  @doc """
  Runs `fun` inside a transaction with the RLS tenant GUC set (`set_config(guc,
  tenant, true)`), so raw `cypher/5` calls inside `fun` are RLS-scoped on the same
  connection. The one auditable way to tenant-scope the raw hatch — do not hand-roll
  `set_config`. `guc`/`tenant` reach Postgres only as bound parameters.

  Diverges from the data layer's internal RLS path in two ways a caller must know:

  - **Blank/nil `tenant` does NOT fail closed.** It is `set_config`'d as-is, so the
    RLS policy's blank-GUC guard yields "no rows visible" rather than an error —
    a silent empty result, not a raised `:rls_tenant_required`. Pass a real tenant.
  - **Errors propagate raw** (this uses `SQL.query!`); it does not redact DB errors,
    unlike the data layer's internal path. The raw hatch already surfaces raw errors
    from your own `cypher/5` calls, so the caller owns error handling here.
  """
  @spec with_tenant_rls(module(), String.t(), term(), (-> result)) :: result when result: var
  def with_tenant_rls(repo, guc, tenant, fun) when is_function(fun, 0) do
    _ = AshAge.Migration.validate_guc!(guc)

    {:ok, result} =
      repo.transaction(fn ->
        SQL.query!(repo, "SELECT set_config($1, $2, true)", [guc, to_string(tenant)])
        fun.()
      end)

    result
  end

  @doc false
  # Decodes one SQL result row into %{column_name => decoded} using the atoms in
  # return_types positionally. Public seam for unit testing without a DB.
  def decode_cypher_row(row, return_types) do
    decode_row(row, column_names(return_types))
  end

  defp column_names(return_types), do: Enum.map(return_types, fn {name, _type} -> name end)

  # Invariant: row arity == length(cols) — AGE's `AS (col agtype, …)` record type
  # must match the RETURN projection or SQL.query raises upstream, so this zip
  # never silently drops columns in practice.
  defp decode_row(row, cols) do
    cols
    |> Enum.zip(row)
    |> Map.new(fn {name, cell} -> {name, Agtype.decode(cell)} end)
  end

  defp row_count({:ok, rows}), do: length(rows)
  defp row_count(_), do: 0
end
