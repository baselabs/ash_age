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
