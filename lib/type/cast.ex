defmodule AshAge.Type.Cast do
  @moduledoc """
  Cast functions for mapping AGE vertex data to Ash resource attributes.
  """

  alias AshAge.Type.Vertex

  # Wire-format tag prefixing every ash_age-encoded binary value. Its purpose is
  # to make read-back deterministic: a stored string carries the tag iff ash_age
  # base64-encoded it, so decoding is never a guess. Legacy or externally-written
  # values (no tag) are returned verbatim — a value that merely *looks* like
  # base64 is never silently decoded. `$` is outside both base64 alphabets, so the
  # tag can never collide with the encoded body. Values reach Cypher only as the
  # `$1` JSON parameter, so the `$` in the tag never touches query syntax.
  @binary_tag "$age64$"

  @doc false
  # Encodes a raw binary value for AGE storage: tag + base64. Used by
  # serialize_value/2 below on the write path (the encode counterpart of the
  # `@binary_tag`-prefixed coerce clause below).
  def encode_binary(value) when is_binary(value), do: @binary_tag <> Base.encode64(value)

  @doc false
  # Resolves `type` to its Ash STORAGE class (`:binary`, `:date`,
  # `:utc_datetime`, `:naive_datetime`, `:string`, ...), through builtin
  # aliases and `Ash.Type.NewType` wrappers, honoring `constraints` exactly
  # the way Ash itself keys sort capability (`Ash.Type.storage_type/2`). This
  # is the ONE type-resolution home — the encoder, the decode gate, the filter
  # cast, and the classification verifiers all key off it (directly or via
  # binary_storage?/2), so a type can never be handled by one path and missed
  # by another. `nil`/unknown types → nil.
  def storage_class(type, constraints \\ [])
  def storage_class(nil, _constraints), do: nil

  def storage_class(type, constraints) do
    resolved = Ash.Type.get_type(type)
    if Ash.Type.ash_type?(resolved), do: Ash.Type.storage_type(resolved, constraints), else: nil
  end

  @doc false
  # TRUE when `type` stores as raw bytes — the classification predicate the
  # verifiers, the range/sort gates, and the encoder share.
  def binary_storage?(type, constraints \\ []), do: storage_class(type, constraints) == :binary

  @doc false
  # Serializes an attribute/argument value for AGE storage or match-param use.
  # Binary-storage values are tagged + base64-encoded so raw bytes survive
  # `Jason.encode!` and read-back is deterministic; date/datetime values become
  # ISO8601; everything else passes through. Moved from AshAge.DataLayer in S7
  # so level-3 modules (Query.Filter) can call it without importing level 5.
  def serialize_value(%DateTime{} = dt, _type), do: DateTime.to_iso8601(dt)
  def serialize_value(%NaiveDateTime{} = ndt, _type), do: NaiveDateTime.to_iso8601(ndt)
  def serialize_value(%Date{} = d, _type), do: Date.to_iso8601(d)

  def serialize_value(value, type) when is_binary(value) do
    if binary_storage?(type), do: encode_binary(value), else: value
  end

  def serialize_value(value, _type), do: value

  @doc """
  Converts a vertex to a map of resource attributes.

  - Extracts `vertex.properties`
  - Includes `vertex.id` mapped to the resource's primary key
  - Applies `attribute_map` for any name remapping
  - Coerces types based on `attribute_types` (e.g., ISO8601 strings -> Date/DateTime)
  """
  @spec vertex_to_resource_attrs(Vertex.t(), map(), map()) :: map()
  def vertex_to_resource_attrs(%Vertex{} = vertex, attribute_map, attribute_types) do
    reverse_map = Map.new(attribute_map, fn {attr_name, prop_name} -> {prop_name, attr_name} end)

    base_attrs =
      vertex.properties
      |> Enum.map(fn {key, val} ->
        resolve_property(to_string(key), val, reverse_map, attribute_types)
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    maybe_put_id(base_attrs, vertex.id)
  end

  def vertex_to_resource_attrs(_other, _attribute_map, _attribute_types), do: %{}

  defp resolve_property(prop_str, value, reverse_map, attribute_types) do
    case Map.get(reverse_map, prop_str) do
      nil -> resolve_by_atom(prop_str, value, attribute_types)
      attr_name -> {attr_name, coerce_value(value, Map.get(attribute_types, attr_name))}
    end
  end

  defp resolve_by_atom(prop_str, value, attribute_types) do
    atom_key = safe_to_existing_atom(prop_str)

    if atom_key && Map.has_key?(attribute_types, atom_key) do
      {atom_key, coerce_value(value, Map.get(attribute_types, atom_key))}
    end
  end

  defp maybe_put_id(attrs, nil), do: attrs
  defp maybe_put_id(attrs, id), do: Map.put_new(attrs, :id, id)

  @doc """
  Coerces a decoded agtype scalar to its Ash attribute `type`.

  Single source of truth for scalar coercion, shared by the vertex-read path
  (`vertex_to_resource_attrs/3`) and the traversal F3 source-key path
  (`AshAge.ManualRelationships.Traverse`). A `nil`/unknown `type` returns the
  value verbatim (identity), so callers may pass a type map that omits a field.
  """
  @spec coerce_value(term(), atom() | module() | nil) :: term()
  def coerce_value(value, type) when is_binary(value) do
    # Dispatch by STORAGE class (not literal type lists) so NewType wrappers
    # coerce exactly like the builtin they store as — the write side
    # serializes %Date{}/%DateTime{} structurally, so the read side must be
    # symmetric for every type whose storage is date/datetime, or a wrapped
    # date PK silently breaks key equality (traverse F3 keyed map).
    case storage_class(type) do
      :date -> coerce_date(value)
      :utc_datetime -> coerce_datetime(value)
      :naive_datetime -> coerce_naive_datetime(value)
      :binary -> coerce_binary(value)
      _ -> value
    end
  end

  def coerce_value(value, _type), do: value

  # Tag-gated decode. Untagged binary-storage values (legacy/pre-tag or
  # externally written) are returned verbatim — READ-ONLY grace: as of S7 the
  # match paths (filter/PK/traverse/edge) send the tagged form, so untagged
  # rows are readable but not matchable through Ash. Never guess-decode a
  # string that merely looks like base64.
  defp coerce_binary(@binary_tag <> encoded = original) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> decoded
      # A tagged value that fails to decode is corrupt/unexpected; return it
      # as stored rather than crash the read path.
      :error -> original
    end
  end

  defp coerce_binary(value), do: value

  defp coerce_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp coerce_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> value
    end
  end

  defp coerce_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> ndt
      _ -> value
    end
  end

  defp safe_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
