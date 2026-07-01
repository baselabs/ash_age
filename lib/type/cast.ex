defmodule AshAge.Type.Cast do
  @moduledoc """
  Cast functions for mapping AGE vertex data to Ash resource attributes.
  """

  alias AshAge.Type.Vertex

  @date_types [
    :date,
    Ash.Type.Date
  ]

  @datetime_types [
    :utc_datetime,
    :utc_datetime_usec,
    Ash.Type.DateTime,
    Ash.Type.UtcDatetime,
    Ash.Type.UtcDatetimeUsec
  ]

  @naive_datetime_types [
    :naive_datetime,
    :naive_datetime_usec,
    Ash.Type.NaiveDatetime
  ]

  @binary_types [
    :binary,
    Ash.Type.Binary
  ]

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
  # AshAge.DataLayer.serialize_value/2 on the write path (the encode counterpart
  # of the `@binary_tag`-prefixed coerce clause below).
  def encode_binary(value) when is_binary(value), do: @binary_tag <> Base.encode64(value)

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

  defp coerce_value(value, type) when is_binary(value) and type in @date_types do
    coerce_date(value)
  end

  defp coerce_value(value, type) when is_binary(value) and type in @datetime_types do
    coerce_datetime(value)
  end

  defp coerce_value(value, type) when is_binary(value) and type in @naive_datetime_types do
    coerce_naive_datetime(value)
  end

  defp coerce_value(@binary_tag <> encoded, type) when type in @binary_types do
    case Base.decode64(encoded) do
      {:ok, decoded} -> decoded
      # A tagged value that fails to decode is corrupt/unexpected; return it as
      # stored rather than crash the read path.
      :error -> @binary_tag <> encoded
    end
  end

  # Untagged binary-typed value: legacy (pre-tag) or externally written. Return
  # it verbatim — never guess-decode a string that merely looks like base64.
  defp coerce_value(value, type) when is_binary(value) and type in @binary_types do
    value
  end

  defp coerce_value(value, _type), do: value

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
