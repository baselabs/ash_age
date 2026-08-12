defmodule AshAge.Cypher.ExprTest do
  use ExUnit.Case, async: true

  alias AshAge.Cypher.Expr
  alias AshAge.Errors.UnsupportedExpression

  alias Ash.Query.Operator.Basic.{Div, Minus, Plus, Times}
  alias Ash.Query.Ref

  # A bare resource-attribute ref: relationship_path empty, attribute carries its name.
  defp ref(name), do: %Ref{attribute: %{name: name}, relationship_path: []}

  # A ref whose attribute also carries a type (the shape Info.attribute_types emits).
  defp typed_ref(name, type),
    do: %Ref{attribute: %{name: name, type: type}, relationship_path: []}

  defp acc, do: %{taken: MapSet.new(), count: 0}

  describe "refs" do
    test "a bare attribute ref emits a backtick-quoted property access" do
      # Backticks are mandatory: a property named `count` collides with Cypher's
      # count() aggregate keyword and mis-parses when bare (AGE probe D-row).
      assert {:ok, "n.`count`", %{}} = Expr.translate(ref(:count), acc())
      assert {:ok, "n.`val`", %{}} = Expr.translate(ref(:val), acc())
    end

    test "the attribute name is validated as an identifier (injection tripwire)" do
      # A malicious attr name carrying Cypher must be rejected, not emitted raw.
      assert {:error, %UnsupportedExpression{}} =
               Expr.translate(
                 %Ref{attribute: %{name: "a`); DETACH DELETE n//"}, relationship_path: []},
                 acc()
               )
    end

    test "a relationship-scoped ref is rejected (Non-goal: rel-scoped expr)" do
      assert {:error, %UnsupportedExpression{}} =
               Expr.translate(%Ref{attribute: %{name: :name}, relationship_path: [:other]}, acc())
    end
  end

  describe "literals" do
    test "an integer literal becomes a positional $param (never interpolated)" do
      assert {:ok, "$p0", %{"p0" => 5}} = Expr.translate(5, acc())
    end

    test "a string literal is parameterized — the value never appears in the fragment" do
      nasty = "x')); DETACH DELETE n //--"

      assert {:ok, frag, %{"p0" => ^nasty}} = Expr.translate(nasty, acc())
      refute frag =~ "DETACH"
      assert frag == "$p0"
    end

    test "consecutive literals allocate distinct positional params" do
      assert {:ok, "$p0", %{"p0" => 1}} = Expr.translate(1, acc())
    end

    test "boolean and nil literals parameterize" do
      assert {:ok, "$p0", %{"p0" => true}} = Expr.translate(true, acc())
      assert {:ok, "$p0", %{"p0" => nil}} = Expr.translate(nil, acc())
    end
  end

  describe "arithmetic operators" do
    test "ref + literal — the headline atomic-increment shape" do
      # SET n.`val` = n.`val` + $p0  ← the prior unverified claim, probe-verified (C2).
      assert {:ok, frag, params} = Expr.translate(%Plus{left: ref(:val), right: 5}, acc())
      assert frag == "n.`val` + $p0"
      assert params == %{"p0" => 5}
    end

    test "ref + ref — both sides bare property accesses" do
      assert {:ok, frag, %{}} = Expr.translate(%Plus{left: ref(:val), right: ref(:num)}, acc())
      assert frag == "n.`val` + n.`num`"
    end

    test "subtract / multiply / divide" do
      assert {:ok, "n.`val` - $p0", %{"p0" => 3}} =
               Expr.translate(%Minus{left: ref(:val), right: 3}, acc())

      assert {:ok, "n.`val` * $p0", %{"p0" => 2}} =
               Expr.translate(%Times{left: ref(:val), right: 2}, acc())

      assert {:ok, "n.`val` / $p0", %{"p0" => 4}} =
               Expr.translate(%Div{left: ref(:val), right: 4}, acc())
    end

    test "nested arithmetic threads positional params left-to-right" do
      # (val + num) * 2  →  (n.`val` + n.`num`) * $p0
      inner = %Plus{left: ref(:val), right: ref(:num)}

      assert {:ok, "(n.`val` + n.`num`) * $p0", %{"p0" => 2}} =
               Expr.translate(%Times{left: inner, right: 2}, acc())
    end

    test "a typed ref is accepted (type reaches the encoder for serialization)" do
      assert {:ok, "n.`val` + $p0", %{"p0" => 1}} =
               Expr.translate(%Plus{left: typed_ref(:val, :integer), right: 1}, acc())
    end
  end

  describe "positional param collision avoidance" do
    test "a param key never collides with a name already taken (plan-review N1)" do
      # If the caller has already used "p0" (e.g. an attr literally named :p0 — unlikely but
      # the JSON boundary silently drops one value if both an atom :p0 and string "p0" land
      # in the merged param map), the translator must allocate a free name.
      taken = MapSet.new(["p0"])
      acc = %{taken: taken, count: 0}

      assert {:ok, "$p0_", %{"p0_" => 5}} = Expr.translate(5, acc)
    end
  end

  describe "unsupported nodes" do
    test "an unrecognized AST node is rejected fail-closed (never a silent drop)" do
      assert {:error, %UnsupportedExpression{}} = Expr.translate(%{some: :unknown_node}, acc())
    end
  end
end
