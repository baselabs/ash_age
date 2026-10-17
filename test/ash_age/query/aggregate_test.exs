defmodule AshAge.Query.AggregateTest do
  use ExUnit.Case, async: true

  alias AshAge.Query.Aggregate

  describe "expr/1 — field-name injection (AGENTS.md rule 3)" do
    # The field NAME is the only interpolated token in the aggregate RETURN expr.
    # validate_identifier! is the defense — this tripwire pins it so a refactor
    # that drops validate_field! ships a red signal, not a Cypher-injection hole.

    test "a tampered (Cypher-smuggling) field name is rejected" do
      # A field name carrying a Cypher break-out: would inject `RETURN n//` if it
      # reached the body unvalidated.
      assert_raise ArgumentError, fn ->
        Aggregate.expr({:sum, "amount) RETURN n//", []})
      end

      assert_raise ArgumentError, fn ->
        Aggregate.expr({:max, :"x} RETURN admin", []})
      end
    end

    test "rejects shell-meta / SQL-meta field names" do
      for bad <- ["amt; DROP", "a b", "n.field", "1bad", "has-dash"] do
        assert_raise ArgumentError, fn -> Aggregate.expr({:sum, bad, []}) end
      end
    end

    test "valid field names render the parameterized RETURN expr (no value interpolation)" do
      # Property refs are backtick-quoted: a field named with a Cypher keyword
      # (`count`, `sum`) mis-parses in AGE as a bare ref — same class as the
      # filter/SET sides fixed in 2.0.0 (prop_ref / set_clauses / Expr).
      assert Aggregate.expr({:count, nil, []}) == "count(n)"
      assert Aggregate.expr({:sum, :amount, []}) == "sum(n.`amount`)"
      assert Aggregate.expr({:max, "score", []}) == "max(n.`score`)"
      assert Aggregate.expr({:count, :email, [uniq?: true]}) == "count(DISTINCT n.`email`)"
      assert Aggregate.expr({:exists, nil, []}) == "count(n)"

      # Cypher-keyword field names themselves
      assert Aggregate.expr({:count, :count, []}) == "count(n.`count`)"
      assert Aggregate.expr({:sum, :sum, []}) == "sum(n.`sum`)"
    end
  end

  describe "expr/1 — structural rejections (loud, not silent)" do
    test "sum/avg/min/max require a field" do
      assert_raise ArgumentError, ~r/requires a field/, fn ->
        Aggregate.expr({:sum, nil, []})
      end
    end

    test "uniq? on sum/avg/min/max is rejected (AGE has no DISTINCT form for these)" do
      assert_raise ArgumentError, ~r/uniq\?: true/, fn ->
        Aggregate.expr({:sum, :amount, [uniq?: true]})
      end
    end
  end

  describe "decode_value/2" do
    test "exists reduces a count to a boolean" do
      assert Aggregate.decode_value(:exists, 0) == false
      assert Aggregate.decode_value(:exists, 3) == true
      assert Aggregate.decode_value(:exists, nil) == false
    end

    test "other kinds pass the decoded value through" do
      assert Aggregate.decode_value(:count, 7) == 7
      assert Aggregate.decode_value(:sum, 60) == 60
      assert Aggregate.decode_value(:avg, 20.0) == 20.0
    end
  end
end
