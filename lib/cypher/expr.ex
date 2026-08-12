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

  alias Ash.Query.Operator.Basic
  alias Ash.Query.Ref
  alias AshAge.Errors.UnsupportedExpression

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

  defp node_label(%{__struct__: mod}), do: mod
  defp node_label(other), do: {:value, other}
end
