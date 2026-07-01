defmodule AshAge.NeverInterpolateTest do
  @moduledoc """
  Regression guarantee: user values reach Cypher ONLY as the `$1` JSON parameter
  of `ag_catalog.cypher(...)`, never interpolated into the query body. Covers both
  the read (filter) and write (create SET) paths.
  """
  use ExUnit.Case, async: true

  alias AshAge.Cypher.Parameterized
  alias AshAge.DataLayer
  alias AshAge.Query
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
end
