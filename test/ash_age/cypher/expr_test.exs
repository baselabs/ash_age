defmodule AshAge.Cypher.ExprTest do
  use ExUnit.Case, async: true

  alias AshAge.Cypher.Expr
  alias AshAge.Errors.UnsupportedExpression

  alias Ash.Query.BooleanExpression

  alias Ash.Query.Function.{
    Contains,
    If,
    Now,
    StringDowncase,
    StringEndsWith,
    StringStartsWith,
    StringTrim
  }

  alias Ash.Query.Not
  alias Ash.Query.Operator.Basic.{Concat, Div, Minus, Plus, Times}

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

  describe "comparison operators" do
    test "eq — literal right side" do
      assert {:ok, "n.`val` = $p0", %{"p0" => 5}} =
               Expr.translate(%Eq{left: ref(:val), right: 5}, acc())
    end

    test "eq — ref right side (attr-to-attr is valid Cypher, unlike the filter path)" do
      assert {:ok, "n.`a` = n.`b`", %{}} =
               Expr.translate(%Eq{left: ref(:a), right: ref(:b)}, acc())
    end

    test "not_eq / gt / lt / gte / lte" do
      assert {:ok, "n.`v` <> $p0", _} = Expr.translate(%NotEq{left: ref(:v), right: 1}, acc())

      assert {:ok, "n.`v` > $p0", _} =
               Expr.translate(%GreaterThan{left: ref(:v), right: 1}, acc())

      assert {:ok, "n.`v` < $p0", _} = Expr.translate(%LessThan{left: ref(:v), right: 1}, acc())

      assert {:ok, "n.`v` >= $p0", _} =
               Expr.translate(%GreaterThanOrEqual{left: ref(:v), right: 1}, acc())

      assert {:ok, "n.`v` <= $p0", _} =
               Expr.translate(%LessThanOrEqual{left: ref(:v), right: 1}, acc())
    end

    test "range ops on a binary-storage attr are rejected (base64 is not byte-orderable)" do
      # S7 invariant: $age64$-tagged base64 does not preserve byte order, so a range
      # comparison on the stored form silently returns wrong results.
      assert {:error, %UnsupportedExpression{}} =
               Expr.translate(%GreaterThan{left: typed_ref(:data, :binary), right: 5}, acc())
    end

    test "in — list right side parameterized" do
      assert {:ok, frag, %{"p0" => [1, 2, 3]}} =
               Expr.translate(%In{left: ref(:v), right: [1, 2, 3]}, acc())

      assert frag == "n.`v` IN $p0"
    end

    test "in — MapSet right side normalized to a list" do
      {:ok, _, %{"p0" => vals}} =
        Expr.translate(%In{left: ref(:v), right: MapSet.new([1, 2])}, acc())

      assert Enum.sort(vals) == [1, 2]
    end

    test "is_nil — IS NULL / IS NOT NULL" do
      assert {:ok, "n.`v` IS NULL", %{}} =
               Expr.translate(%IsNil{left: ref(:v), right: true}, acc())

      assert {:ok, "n.`v` IS NOT NULL", %{}} =
               Expr.translate(%IsNil{left: ref(:v), right: false}, acc())
    end
  end

  describe "boolean combinators" do
    test "and / or parenthesize both branches" do
      l = %Eq{left: ref(:a), right: 1}
      r = %Eq{left: ref(:b), right: 2}

      assert {:ok, "(n.`a` = $p0) AND (n.`b` = $p1)", _} =
               Expr.translate(%BooleanExpression{op: :and, left: l, right: r}, acc())

      assert {:ok, "(n.`a` = $p0) OR (n.`b` = $p1)", _} =
               Expr.translate(%BooleanExpression{op: :or, left: l, right: r}, acc())
    end

    test "not" do
      inner = %Eq{left: ref(:a), right: 1}
      assert {:ok, "NOT (n.`a` = $p0)", _} = Expr.translate(%Not{expression: inner}, acc())
    end
  end

  describe "control + string functions" do
    test "if — CASE WHEN .. THEN .. ELSE .. END" do
      cond = %GreaterThan{left: ref(:count), right: 10}

      assert {:ok, frag, %{"p0" => 10, "p1" => 999, "p2" => 0}} =
               Expr.translate(%If{arguments: [cond, 999, 0]}, acc())

      assert frag == "CASE WHEN n.`count` > $p0 THEN $p1 ELSE $p2 END"
    end

    test "string_downcase / string_trim" do
      assert {:ok, "toLower(n.`name`)", %{}} =
               Expr.translate(%StringDowncase{arguments: [ref(:name)]}, acc())

      assert {:ok, "trim(n.`name`)", %{}} =
               Expr.translate(%StringTrim{arguments: [ref(:name)]}, acc())
    end

    test "string_starts_with / string_ends_with / contains — predicates" do
      assert {:ok, "n.`name` STARTS WITH $p0", %{"p0" => "pre"}} =
               Expr.translate(%StringStartsWith{arguments: [ref(:name), "pre"]}, acc())

      assert {:ok, "n.`name` ENDS WITH $p0", %{"p0" => "suf"}} =
               Expr.translate(%StringEndsWith{arguments: [ref(:name), "suf"]}, acc())

      assert {:ok, "n.`name` CONTAINS $p0", %{"p0" => "mid"}} =
               Expr.translate(%Contains{arguments: [ref(:name), "mid"]}, acc())
    end
  end

  describe "string concat" do
    test "Basic.Concat maps to AGE's + operator (AGE uses <> for not-equal)" do
      # Probe C8: n.nm + '-X' → "Widget-X". Ash's :<> must emit +, not <>.
      assert {:ok, "n.`name` + $p0", %{"p0" => "-X"}} =
               Expr.translate(%Concat{left: ref(:name), right: "-X"}, acc())
    end
  end

  describe "rejected functions (fail-closed, plan Decision D-rev4)" do
    # Each of these is rejected with UnsupportedExpression — never a silent drop.
    # They are owned by named follow-ups (time-expr, rel-scoped-expr) or are
    # mechanically forbidden (Fragment — rule 1).
    test "now() rejected (purity + clock-skew; owned by time-expr)" do
      assert {:error, %UnsupportedExpression{}} = Expr.translate(%Now{arguments: []}, acc())
    end
  end

  describe "unsupported nodes" do
    test "an unrecognized AST node is rejected fail-closed (never a silent drop)" do
      assert {:error, %UnsupportedExpression{}} = Expr.translate(%{some: :unknown_node}, acc())
    end
  end
end
