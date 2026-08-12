defmodule AshAge.Cypher.Expr do
  @moduledoc """
  Translates an `Ash.Expr` AST fragment into a Cypher expression string + a
  param map, for use in `SET` clauses (atomic updates) and expression filters.

  Pure: holds no state, performs no I/O, reads no clock. Every dynamic value
  becomes a positional `$param` (AGENTS.md Critical Security Rule 1 — no value
  is ever interpolated into the Cypher string). Every property reference is
  backtick-quoted and identifier-validated: a property whose name collides with
  a Cypher keyword (`count`, `label`, …) mis-parses when bare, a vulnerability
  closed by mandatory `` n.`attr` `` quoting (AGE probe D-row). Returns
  `{:error, UnsupportedExpression}` for any node it cannot safely map — never
  a silent drop.

  ## Param allocation

  Param names are positional (`p0`, `p1`, …) allocated against the caller's
  `taken` set so they cannot collide with attribute-name params at the JSON
  boundary (an atom `:p0` and string `"p0"` in the merged param map would
  produce a duplicate JSON key, silently dropping one value — plan-review N1).
  """

  alias Ash.Query.BooleanExpression

  alias Ash.Query.Function.{
    Contains,
    Error,
    If,
    StringDowncase,
    StringEndsWith,
    StringStartsWith,
    StringTrim,
    Type
  }

  alias Ash.Query.Not
  alias Ash.Query.Operator.Basic

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
  alias AshAge.Errors.UnsupportedExpression
  alias AshAge.Type.Cast

  @type acc :: %{taken: MapSet.t(String.t()), count: non_neg_integer()}
  @type result :: {:ok, String.t(), map()} | {:error, term()}

  @doc """
  Translate `expr` into a Cypher fragment and a map of `$param => value`.

  `acc` carries the caller's already-taken param names (`:taken`) and an
  allocation counter (`:count`); the translator allocates collision-free
  positional names against them.
  """
  @spec translate(term(), acc()) :: result()
  def translate(expr, %{taken: taken, count: count}) do
    internal = %{taken: taken, count: count, params: %{}}

    case do_translate(expr, internal) do
      {:ok, frag, acc} -> {:ok, frag, acc.params}
      {:error, _} = err -> err
    end
  end

  # --- Refs --------------------------------------------------------------

  # A bare resource-attribute ref: relationship_path empty. Backtick-quote the
  # validated attr name — mandatory, since `n.count` (keyword) mis-parses.
  defp do_translate(%Ref{relationship_path: [], attribute: %{name: name}}, acc)
       when is_atom(name) or is_binary(name) do
    name_str = to_string(name)

    case validate(name_str) do
      :ok -> {:ok, "n.`#{name_str}`", acc}
      {:error, reason} -> {:error, unsupported({:ref, name}, reason)}
    end
  end

  # A relationship-scoped ref (path non-empty) is a Non-goal for this slice
  # (rel-scoped expr requires a sub-MATCH). Reject fail-closed.
  defp do_translate(%Ref{relationship_path: [_ | _]} = ref, _acc) do
    path = Ref.name(ref) || ref.relationship_path
    {:error, unsupported({:ref, path}, "relationship-scoped refs are not translated (Non-goal)")}
  end

  # --- Literals → positional $param (never interpolated) -----------------

  defp do_translate(value, acc) when is_integer(value) or is_float(value) do
    alloc_param(acc, value)
  end

  defp do_translate(value, acc) when is_binary(value) do
    alloc_param(acc, value)
  end

  defp do_translate(value, acc) when is_boolean(value) do
    alloc_param(acc, value)
  end

  defp do_translate(nil, acc) do
    alloc_param(acc, nil)
  end

  # --- Arithmetic operators (probe-verified AGE support) -----------------

  defp do_translate(%Basic.Plus{left: left, right: right}, acc),
    do: binop(left, "+", right, acc)

  defp do_translate(%Basic.Minus{left: left, right: right}, acc),
    do: binop(left, "-", right, acc)

  defp do_translate(%Basic.Times{left: left, right: right}, acc),
    do: binop(left, "*", right, acc)

  defp do_translate(%Basic.Div{left: left, right: right}, acc),
    do: binop(left, "/", right, acc)

  # String concat. Ash uses :<> for concat; AGE uses <> for NOT-EQUAL, so this
  # MUST emit + (probe C8: n.nm + '-X' → "Widget-X"). A naive symbol-mapping
  # would silently produce a not-equal predicate.
  defp do_translate(%Basic.Concat{left: left, right: right}, acc),
    do: binop(left, "+", right, acc)

  # --- Comparison operators ----------------------------------------------

  defp do_translate(%Eq{left: left, right: right}, acc),
    do: binop(left, "=", right, acc)

  defp do_translate(%NotEq{left: left, right: right}, acc),
    do: binop(left, "<>", right, acc)

  # Range ops reject binary-storage attrs: the $age64$ base64 wire form is not
  # byte-order-preserving, so a range comparison silently returns wrong results
  # (S7 invariant, mirrored from Filter.translate's rangeable/2).
  defp do_translate(%GreaterThan{left: %Ref{attribute: attr} = left, right: right}, acc),
    do: range_compare(left, ">", right, attr, acc)

  defp do_translate(%LessThan{left: %Ref{attribute: attr} = left, right: right}, acc),
    do: range_compare(left, "<", right, attr, acc)

  defp do_translate(%GreaterThanOrEqual{left: %Ref{attribute: attr} = left, right: right}, acc),
    do: range_compare(left, ">=", right, attr, acc)

  defp do_translate(%LessThanOrEqual{left: %Ref{attribute: attr} = left, right: right}, acc),
    do: range_compare(left, "<=", right, attr, acc)

  defp do_translate(%In{left: left, right: %MapSet{} = set}, acc),
    do: do_translate(%In{left: left, right: MapSet.to_list(set)}, acc)

  defp do_translate(%In{left: left, right: values}, acc) when is_list(values) do
    with {:ok, lfrag, acc} <- operand(left, acc),
         {:ok, acc, name} <- alloc_list_param(acc, values) do
      {:ok, "#{lfrag} IN $#{name}", acc}
    end
  end

  defp do_translate(%IsNil{left: left, right: true}, acc) do
    with {:ok, lfrag, acc} <- operand(left, acc), do: {:ok, "#{lfrag} IS NULL", acc}
  end

  defp do_translate(%IsNil{left: left, right: false}, acc) do
    with {:ok, lfrag, acc} <- operand(left, acc), do: {:ok, "#{lfrag} IS NOT NULL", acc}
  end

  # --- Boolean combinators ----------------------------------------------

  defp do_translate(%BooleanExpression{op: :and, left: left, right: right}, acc),
    do: bool_op("AND", left, right, acc)

  defp do_translate(%BooleanExpression{op: :or, left: left, right: right}, acc),
    do: bool_op("OR", left, right, acc)

  defp do_translate(%Not{expression: inner}, acc) do
    with {:ok, frag, acc} <- operand(inner, acc), do: {:ok, "NOT (#{frag})", acc}
  end

  # --- Control + string functions ---------------------------------------

  # Ash's `allow_nil?: false` validation wrapper, generated by fully_atomic_changeset:
  #   if is_nil(type(expr, Type, [])) do error(...) else expr end
  # AGE is dynamically typed (type/3 unwraps) and cannot raise an Ash error in
  # Cypher, and the literal CASE WHEN form errors on AGE's IS NULL over an
  # arithmetic expression. Reduce the whole wrapper to its inner expr — the
  # null-check becomes an app-layer concern (documented limitation: allow_nil? on
  # atomic results isn't DB-enforced for AGE, same class as no-PK-uniqueness).
  # This clause MUST precede the general If → CASE WHEN clause.
  defp do_translate(
         %If{
           arguments: [
             %IsNil{left: %Type{arguments: [_ | _]}, right: _},
             %Error{},
             else_expr
           ]
         },
         acc
       ) do
    do_translate(else_expr, acc)
  end

  defp do_translate(%If{arguments: [cond, then_ast, else_ast]}, acc) do
    with {:ok, cfrag, acc} <- operand(cond, acc),
         {:ok, tfrag, acc} <- operand(then_ast, acc),
         {:ok, efrag, acc} <- operand(else_ast, acc) do
      {:ok, "CASE WHEN #{cfrag} THEN #{tfrag} ELSE #{efrag} END", acc}
    end
  end

  defp do_translate(%StringDowncase{arguments: [arg]}, acc),
    do: unary_fn("toLower", arg, acc)

  defp do_translate(%StringTrim{arguments: [arg]}, acc),
    do: unary_fn("trim", arg, acc)

  defp do_translate(%StringStartsWith{arguments: [left, right]}, acc),
    do: predicate_fn(left, "STARTS WITH", right, acc)

  defp do_translate(%StringEndsWith{arguments: [left, right]}, acc),
    do: predicate_fn(left, "ENDS WITH", right, acc)

  defp do_translate(%Contains{arguments: [left, right]}, acc),
    do: predicate_fn(left, "CONTAINS", right, acc)

  # Ash's type-assertion wrapper. AGE is dynamically typed, so the cast is a
  # no-op — translate the inner expr and drop the type/constraints args. The
  # wrapper appears on every atomic update of an allow_nil?: false attr
  # (`if is_nil(type(expr, Type, [])) do error else expr end`).
  defp do_translate(%Type{arguments: [expr | _]}, acc), do: do_translate(expr, acc)

  # A bare `Ash.Query.Function.Error{}` reachable here means an atomic
  # VALIDATION produced `if(violation, error(...), ref(attr))` (Ash's
  # `add_atomic_validations`, changeset.ex:3998-40119) and the allow_nil?
  # wrapper clause above did NOT strip it (its cond is a compare/other, not
  # `is_nil(type(expr))`). AGE Cypher cannot raise an Ash error from a SET
  # expression, so translating `error(...)` to `null` would emit
  # `SET attr = CASE WHEN violation THEN null ELSE attr END` — a validation
  # violation would write null and SUCCEED (silent bypass + data corruption,
  # cross-vendor closeout finding B1). Fail CLOSED instead: reject the node so
  # the changeset is not translated to a Cypher write. AGE-side enforcement of
  # atomic validations is a named limitation (validations must run per-record).
  defp do_translate(%Error{arguments: _}, _acc) do
    {:error,
     unsupported(
       Ash.Query.Function.Error,
       "Ash.Query.Function.Error is not translatable — AGE cannot raise in a SET expression; " <>
         "atomic validations must run on the per-record path"
     )}
  end

  # --- Catch-all: fail-closed (never a silent drop) ----------------------

  defp do_translate(node, _acc) do
    {:error,
     unsupported(node_label(node), "the Cypher translator does not map this Ash.Expr node")}
  end

  # --- Internals ---------------------------------------------------------

  # Binary arithmetic: recurse both sides, parenthesize a sub-operand that is
  # itself arithmetic so precedence is preserved (e.g. (a + b) * c).
  defp binop(left, op, right, acc) do
    with {:ok, lfrag, acc} <- operand(left, acc),
         {:ok, rfrag, acc} <- operand(right, acc) do
      {:ok, "#{lfrag} #{op} #{rfrag}", acc}
    end
  end

  defp operand(node, acc) do
    case do_translate(node, acc) do
      {:ok, frag, acc} ->
        if arithmetic?(node), do: {:ok, "(#{frag})", acc}, else: {:ok, frag, acc}

      err ->
        err
    end
  end

  defp arithmetic?(%Basic.Plus{}), do: true
  defp arithmetic?(%Basic.Minus{}), do: true
  defp arithmetic?(%Basic.Times{}), do: true
  defp arithmetic?(%Basic.Div{}), do: true
  defp arithmetic?(_), do: false

  # Range comparison: gate the binary-storage check before emitting. A
  # binary-storage attr's $age64$ base64 wire form is not byte-orderable, so a
  # range op on it silently returns wrong results.
  defp range_compare(left, op, right, attr, acc) do
    with :ok <- rangeable(attr) do
      binop(left, op, right, acc)
    end
  end

  defp rangeable(attr) do
    if Cast.binary_storage?(attr_type(attr), attr_constraints(attr)) do
      {:error,
       unsupported({:range_op, attr_name(attr)}, "range op on a binary-storage attribute")}
    else
      :ok
    end
  end

  defp attr_type(%{type: type}), do: type
  defp attr_type(_), do: nil

  defp attr_constraints(%{constraints: c}) when is_list(c), do: c
  defp attr_constraints(_), do: []

  defp attr_name(%{name: name}), do: name
  defp attr_name(_), do: nil

  # Allocate a positional param holding a LIST (for IN). Each element is
  # serialized through the same encoder the read path uses; an empty list is a
  # valid "match nothing" (no guard needed).
  defp alloc_list_param(acc, values) do
    serialized = Enum.map(values, &Cast.serialize_value(&1, nil))
    base = "p#{acc.count}"
    name = free_name(acc.taken, base)

    acc = %{
      acc
      | taken: MapSet.put(acc.taken, name),
        count: acc.count + 1,
        params: Map.put(acc.params, name, serialized)
    }

    {:ok, acc, name}
  end

  defp bool_op(keyword, left, right, acc) do
    with {:ok, lfrag, acc} <- operand(left, acc),
         {:ok, rfrag, acc} <- operand(right, acc) do
      {:ok, "(#{lfrag}) #{keyword} (#{rfrag})", acc}
    end
  end

  defp unary_fn(name, arg, acc) do
    with {:ok, frag, acc} <- operand(arg, acc), do: {:ok, "#{name}(#{frag})", acc}
  end

  defp predicate_fn(left, keyword, right, acc) do
    with {:ok, lfrag, acc} <- operand(left, acc),
         {:ok, rfrag, acc} <- operand(right, acc) do
      {:ok, "#{lfrag} #{keyword} #{rfrag}", acc}
    end
  end

  # Allocate a positional param name that does not collide with anything
  # already in `taken`. Append underscores until free (mirrors the
  # data_layer.ex `unique_key/2` discipline used for PK-match params).
  defp alloc_param(acc, value) do
    base = "p#{acc.count}"
    name = free_name(acc.taken, base)

    acc = %{
      acc
      | taken: MapSet.put(acc.taken, name),
        count: acc.count + 1,
        params: Map.put(acc.params, name, value)
    }

    {:ok, "$#{name}", acc}
  end

  defp free_name(taken, base) do
    if MapSet.member?(taken, base), do: free_name(taken, base <> "_"), else: base
  end

  defp validate(name) do
    # validate_identifier! raises ArgumentError whose message echoes `inspect(name)`
    # (lib/migration.ex:158) — so we NEVER embed the exception message; return a
    # static, value-free reason (AGENTS.md rule 5). The name is still rejected.
    AshAge.Migration.validate_identifier!(name)
    :ok
  rescue
    ArgumentError ->
      {:error, "attribute name failed identifier validation"}
  end

  defp unsupported(node, reason), do: UnsupportedExpression.exception(node: node, reason: reason)

  # Structural label for the `node` field of `UnsupportedExpression` (whose
  # message inspects `node`). A struct → its module; anything else → a fixed
  # `:value` atom — NEVER the bare value, which could be PII/secret (cross-vendor
  # closeout finding: the prior `{:value, other}` captured + inspected the value,
  # contradicting the value-free error boundary).
  defp node_label(%{__struct__: mod}), do: mod
  defp node_label(_other), do: :value
end
