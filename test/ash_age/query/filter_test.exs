defmodule AshAge.Query.FilterTest do
  use ExUnit.Case, async: true

  alias AshAge.Errors.UnsupportedFilter
  alias AshAge.Query
  alias AshAge.Query.Filter
  alias AshAge.Type.Cast

  alias Ash.Query.BooleanExpression
  alias Ash.Query.Not

  alias Ash.Query.Operator.{
    Eq,
    GreaterThan,
    GreaterThanOrEqual,
    In,
    IsNil,
    LessThan,
    LessThanOrEqual,
    NotEq
  }

  alias Ash.Query.Ref

  defp q, do: %Query{resource: __MODULE__, graph: :g, label: :L, repo: __MODULE__, params: %{}}

  defp ref(name), do: %Ref{attribute: %{name: name}}

  defp typed_ref(name, type), do: %Ref{attribute: %{name: name, type: type, constraints: []}}

  describe "comparison operators" do
    test "eq parameterizes the value (value never appears in the clause)" do
      {:ok, query, clause} = Filter.translate(%Eq{left: ref(:name), right: "Robert'); DROP"}, q())

      assert clause == "n.name = $param1"
      assert query.params == %{"param1" => "Robert'); DROP"}
      refute clause =~ "Robert"
    end

    test "not_eq" do
      {:ok, query, clause} = Filter.translate(%NotEq{left: ref(:age), right: 30}, q())
      assert clause == "n.age <> $param1"
      assert query.params == %{"param1" => 30}
    end

    test "greater_than / less_than" do
      {:ok, _, gt} = Filter.translate(%GreaterThan{left: ref(:age), right: 18}, q())
      {:ok, _, lt} = Filter.translate(%LessThan{left: ref(:age), right: 65}, q())
      assert gt == "n.age > $param1"
      assert lt == "n.age < $param1"
    end

    test "gte / lte" do
      {:ok, _, gte} = Filter.translate(%GreaterThanOrEqual{left: ref(:age), right: 18}, q())
      {:ok, _, lte} = Filter.translate(%LessThanOrEqual{left: ref(:age), right: 65}, q())
      assert gte == "n.age >= $param1"
      assert lte == "n.age <= $param1"
    end

    test "in parameterizes the whole list" do
      {:ok, query, clause} = Filter.translate(%In{left: ref(:status), right: ["a", "b"]}, q())
      assert clause == "n.status IN $param1"
      assert query.params == %{"param1" => ["a", "b"]}
    end

    test "in with a MapSet right side (the real Ash In shape) parameterizes the whole list" do
      {:ok, query, clause} =
        Filter.translate(%In{left: ref(:status), right: MapSet.new(["a", "b"])}, q())

      assert clause == "n.status IN $param1"
      # the param carries the list value (order-independent — MapSet has no order)
      assert query.params |> Map.values() |> List.first() |> Enum.sort() == ["a", "b"]
    end
  end

  describe "is_nil" do
    test "true -> IS NULL, no param" do
      {:ok, query, clause} = Filter.translate(%IsNil{left: ref(:deleted_at), right: true}, q())
      assert clause == "n.deleted_at IS NULL"
      assert query.params == %{}
    end

    test "false -> IS NOT NULL" do
      {:ok, _, clause} = Filter.translate(%IsNil{left: ref(:deleted_at), right: false}, q())
      assert clause == "n.deleted_at IS NOT NULL"
    end
  end

  describe "boolean expressions" do
    test "and / or nest with parentheses and sequential params" do
      expr = %BooleanExpression{
        op: :and,
        left: %Eq{left: ref(:a), right: 1},
        right: %BooleanExpression{
          op: :or,
          left: %Eq{left: ref(:b), right: 2},
          right: %Eq{left: ref(:c), right: 3}
        }
      }

      {:ok, query, clause} = Filter.translate(expr, q())
      assert clause == "(n.a = $param1 AND (n.b = $param2 OR n.c = $param3))"
      assert query.params == %{"param1" => 1, "param2" => 2, "param3" => 3}
    end

    test "not wraps its clause" do
      {:ok, _, clause} = Filter.translate(%Not{expression: %Eq{left: ref(:a), right: 1}}, q())
      assert clause == "NOT (n.a = $param1)"
    end
  end

  describe "value casting" do
    test "DateTime is cast to an ISO8601 string parameter" do
      dt = ~U[2026-06-30 12:00:00Z]
      {:ok, query, _} = Filter.translate(%Eq{left: ref(:inserted_at), right: dt}, q())
      assert query.params == %{"param1" => "2026-06-30T12:00:00Z"}
    end

    test "Date is cast to an ISO8601 string parameter" do
      {:ok, query, _} = Filter.translate(%Eq{left: ref(:dob), right: ~D[2000-01-01]}, q())
      assert query.params == %{"param1" => "2000-01-01"}
    end
  end

  describe "unsupported filters" do
    test "returns an UnsupportedFilter error for anything not pushed down" do
      assert {:error, %UnsupportedFilter{}} = Filter.translate(%{some: :unknown_expr}, q())
    end
  end

  describe "binary-storage attribute encoding (S7)" do
    test "eq on a binary-storage attribute sends the tagged form" do
      raw = <<0, 255, 1>>

      {:ok, query, clause} =
        Filter.translate(%Eq{left: typed_ref(:payload, Ash.Type.Binary), right: raw}, q())

      assert clause == "n.payload = $param1"
      assert query.params == %{"param1" => Cast.encode_binary(raw)}
    end

    test "in on a binary-storage attribute encodes every element" do
      raws = [<<1, 255>>, <<2, 254>>]

      {:ok, query, clause} =
        Filter.translate(%In{left: typed_ref(:payload, Ash.Type.Binary), right: raws}, q())

      assert clause == "n.payload IN $param1"
      assert query.params == %{"param1" => Enum.map(raws, &Cast.encode_binary/1)}
    end

    test "not_eq on a binary-storage attribute sends the tagged form" do
      raw = <<0, 255, 1>>

      {:ok, query, clause} =
        Filter.translate(%NotEq{left: typed_ref(:payload, Ash.Type.Binary), right: raw}, q())

      assert clause == "n.payload <> $param1"
      assert query.params == %{"param1" => Cast.encode_binary(raw)}
    end

    test "attribute-to-attribute comparison is UnsupportedFilter, not a poisoned param" do
      # A Ref on the RIGHT side has no bindable value; binding the struct would
      # surface downstream as a misleading "params not JSON-encodable" error.
      right = %Ref{attribute: %{name: :other, type: Ash.Type.String, constraints: []}}

      for op <- [Eq, NotEq, GreaterThan] do
        assert {:error, %UnsupportedFilter{field: :payload}} =
                 Filter.translate(
                   struct(op, left: typed_ref(:payload, Ash.Type.Binary), right: right),
                   q()
                 )
      end
    end

    test "eq on a string attribute is untouched (tenant filters stay raw)" do
      {:ok, query, _} =
        Filter.translate(%Eq{left: typed_ref(:tenant_id, Ash.Type.String), right: "t1"}, q())

      assert query.params == %{"param1" => "t1"}
    end

    test "a ref without a type passes the value through unchanged" do
      {:ok, query, _} = Filter.translate(%Eq{left: ref(:name), right: "x"}, q())
      assert query.params == %{"param1" => "x"}
    end

    test "range operators on a binary-storage attribute are UnsupportedFilter" do
      for op <- [GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual] do
        assert {:error, %UnsupportedFilter{field: :payload}} =
                 Filter.translate(
                   struct(op, left: typed_ref(:payload, Ash.Type.Binary), right: <<1>>),
                   q()
                 )
      end
    end

    test "range operators on non-binary attributes still work" do
      {:ok, _query, clause} =
        Filter.translate(%GreaterThan{left: typed_ref(:age, Ash.Type.Integer), right: 30}, q())

      assert clause == "n.age > $param1"
    end
  end
end
