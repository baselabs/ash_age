defmodule AshAge.NeverInterpolateTest do
  @moduledoc """
  Regression guarantee: user values reach Cypher ONLY as the `$1` JSON parameter
  of `ag_catalog.cypher(...)`, never interpolated into the query body. Covers the
  read (filter), create (SET), and update/destroy (primary-key WHERE) paths.
  """
  use ExUnit.Case, async: true

  alias AshAge.Changes.{CreateEdge, DestroyEdge, EdgeCypher}
  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer
  alias AshAge.Query
  alias AshAge.Query.Aggregate
  alias AshAge.Query.Filter

  alias Ash.Query.Operator.{Eq, In}
  alias Ash.Query.Ref

  @secret "SUPER-SECRET-VALUE-42"

  defp q, do: %Query{resource: __MODULE__, graph: :g, label: :L, repo: __MODULE__, params: %{}}
  defp ref(name), do: %Ref{attribute: %{name: name}}

  test "an equality filter value appears only in the $1 params, never in the SQL body" do
    {:ok, query, clause} = Filter.translate(%Eq{left: ref(:name), right: @secret}, q())

    refute clause =~ @secret
    assert @secret in Map.values(query.params)

    {sql, [json]} = Parameterized.build(:g, "MATCH (n:L) WHERE #{clause} RETURN n", query.params)
    refute sql =~ @secret
    assert json =~ @secret
  end

  test "an IN filter's values appear only in the $1 params, never in the SQL body" do
    {:ok, query, clause} = Filter.translate(%In{left: ref(:name), right: [@secret, "other"]}, q())

    refute clause =~ @secret

    {sql, [json]} = Parameterized.build(:g, "MATCH (n:L) WHERE #{clause} RETURN n", query.params)
    refute sql =~ @secret
    assert json =~ @secret
  end

  test "a created property's value appears only in the $1 params, never in the SQL body" do
    props = %{"name" => @secret}
    clauses = DataLayer.set_clauses(props)

    refute clauses =~ @secret

    {sql, [json]} = Parameterized.build(:g, "CREATE (n:L) SET #{clauses} RETURN n", props)
    refute sql =~ @secret
    assert json =~ @secret
  end

  test "an update/destroy primary-key match value appears only in the $1 params, never in the SQL body" do
    {where_clause, params} = DataLayer.pk_match_clause([{:id, @secret}], %{})

    refute where_clause =~ @secret
    assert @secret in Map.values(params)

    {sql, [json]} =
      Parameterized.build(:g, "MATCH (n:L) WHERE #{where_clause} RETURN n", params)

    refute sql =~ @secret
    assert json =~ @secret
  end

  test "an edge source-PK and tenant value appear only in the $1 params, never in the SQL body" do
    {src_clause, src_params} = EdgeCypher.source_where([{"id", @secret}])

    {tenant_clause, tenant_params} =
      EdgeCypher.tenant_where({"org", "org", @secret, @secret})

    refute src_clause =~ @secret
    refute tenant_clause =~ @secret
    assert @secret in Map.values(src_params)
    assert @secret in Map.values(tenant_params)

    params = Map.merge(src_params, tenant_params)

    {sql, [json]} =
      Parameterized.build(
        :g,
        "MATCH (a:L), (b:L) WHERE a.`id` = $src_id#{tenant_clause} RETURN a",
        params
      )

    refute sql =~ @secret
    assert json =~ @secret
  end

  test "a bulk-create row's values appear only in the $1 params ($rows), never in the SQL body" do
    rows = [%{"name" => @secret, "note" => "x"}, %{"name" => "other"}]

    {sql, [json]} =
      Parameterized.build(:g, "UNWIND $rows AS row CREATE (n:L) SET n.`name` = row.`name`", %{
        "rows" => rows
      })

    refute sql =~ @secret
    assert json =~ @secret
  end

  # AGENTS.md rule 2: MERGE has catastrophic performance bugs in AGE and is
  # banned from every emitted statement. Invariant tripwire: every pure Cypher
  # builder must emit CREATE/MATCH/SET/DELETE, never MERGE.
  test "no pure builder ever emits MERGE" do
    defmodule M do
      use Ash.Resource,
        domain: AshAge.TestDomain,
        validate_domain_inclusion?: false,
        data_layer: AshAge.DataLayer

      age do
        graph(:never_interpolate)
        repo(AshAge.TestRepo)
        label(:M)
      end

      attributes do
        uuid_primary_key(:id)
      end
    end

    q = %Query{
      resource: M,
      graph: :never_interpolate,
      label: :M,
      repo: AshAge.TestRepo,
      params: %{}
    }

    edge = %AshAge.Edge{
      name: :rel,
      label: :REL,
      direction: :outgoing,
      destination: M,
      properties: []
    }

    builders = [
      fn -> DataLayer.set_clauses(%{"name" => "v"}) end,
      fn -> DataLayer.pk_match_clause([{:id, "v"}], %{}) |> elem(0) end,
      fn -> Query.to_cypher(q) |> elem(0) end,
      fn -> Query.delete_cypher(q, :M) |> elem(0) end,
      fn -> Query.update_cypher(q, :M, "n.`name` = $name") |> elem(0) end,
      fn -> Query.duplicate_pk_cypher(q, :M, [:id]) |> elem(0) end,
      fn -> Aggregate.expr({:count, :name, []}) end,
      fn ->
        CreateEdge.build_create(M, edge, %{"id" => "s"}, "d", %{w: 1}, nil)
        |> elem(0)
      end,
      fn ->
        DestroyEdge.build_destroy(M, edge, %{"id" => "s"}, "d", nil) |> elem(0)
      end
    ]

    for builder <- builders do
      output = builder.()

      refute output =~ "MERGE",
             "a pure builder emitted MERGE (banned: AGENTS.md rule 2): #{output}"
    end
  end
end
