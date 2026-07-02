defmodule AshAge.Type.Agtype do
  @moduledoc """
  AGType decoder for PostgreSQL AGE graph data.

  AGE returns text in formats like:

      {"id": 844424930131969, "label": "Person", "properties": {"name": "Usman"}}::vertex
      {"id": N, "label": "L", "end_id": N, "start_id": N, "properties": {...}}::edge
      [{...}::vertex, {...}::edge, {...}::vertex, ...]::path

  For vertices and edges this module strips the type suffix, JSON-decodes the
  body, and maps to the appropriate struct. A `::path` body is NOT plain JSON:
  each element is itself a fully tagged `::vertex`/`::edge` agtype, so the path
  decoder splits the array at top-level commas and recursively decodes each
  element, then partitions the results into vertices and edges (order preserved).
  """

  alias AshAge.Type.{Edge, Path, Vertex}

  @type_suffix_pattern ~r/^(.+)::(vertex|edge|path)\s*$/s

  @doc """
  Decodes an agtype string into an Elixir struct.

  Returns a `%Vertex{}`, `%Edge{}`, `%Path{}`, or a scalar value.
  """
  @spec decode(binary()) :: Vertex.t() | Edge.t() | Path.t() | term()
  def decode(agtype_string) when is_binary(agtype_string) do
    case Regex.run(@type_suffix_pattern, agtype_string) do
      [_, json_body, "vertex"] ->
        decode_vertex(json_body)

      [_, json_body, "edge"] ->
        decode_edge(json_body)

      [_, json_body, "path"] ->
        decode_path(json_body)

      nil ->
        decode_scalar(agtype_string)
    end
  end

  def decode(other), do: other

  defp decode_vertex(json) do
    data = Jason.decode!(json)

    %Vertex{
      id: data["id"],
      label: data["label"],
      properties: data["properties"] || %{}
    }
  end

  defp decode_edge(json) do
    data = Jason.decode!(json)

    %Edge{
      id: data["id"],
      label: data["label"],
      start_id: data["start_id"],
      end_id: data["end_id"],
      properties: data["properties"] || %{}
    }
  end

  # `decode_path/1` receives the array body (the part before `::path`), e.g.
  # `[{...}::vertex, {...}::edge, {...}::vertex]`. Each element is itself a
  # fully tagged agtype (`::vertex`/`::edge`), so the body is NOT plain JSON.
  # We strip the outer brackets, split at top-level commas (depth- and
  # string-literal-aware), then recursively `decode/1` each element and
  # partition by struct type (order preserved within each list).
  defp decode_path(body) do
    structs =
      body
      |> String.trim()
      |> strip_array_brackets()
      |> split_top_level()
      |> Enum.map(&decode/1)

    vertices = Enum.filter(structs, &match?(%Vertex{}, &1))
    edges = Enum.filter(structs, &match?(%Edge{}, &1))

    %Path{vertices: vertices, edges: edges}
  end

  defp strip_array_brackets(str) do
    case str do
      "[" <> rest -> rest |> String.reverse() |> strip_leading_bracket() |> String.reverse()
      other -> other
    end
  end

  defp strip_leading_bracket("]" <> rest), do: rest
  defp strip_leading_bracket(other), do: other

  # Splits the array body at top-level commas only, tracking `{}`/`[]` nesting
  # depth and string-literal state (with `\`-escapes) so commas inside element
  # objects or quoted strings do not split. Returns trimmed element strings,
  # dropping any empty trailing segment (empty path body).
  defp split_top_level(str) do
    str
    |> do_split(0, false, false, "", [])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Args: depth, in_string?, escaped?, current-segment acc, completed segments (reversed).
  defp do_split(<<>>, _depth, _in_str, _esc, current, acc), do: Enum.reverse([current | acc])

  defp do_split(<<c::utf8, rest::binary>>, depth, true, true, current, acc) do
    # Previous char was a backslash inside a string: this char is literal.
    do_split(rest, depth, true, false, <<current::binary, c::utf8>>, acc)
  end

  defp do_split(<<?\\, rest::binary>>, depth, true, false, current, acc) do
    do_split(rest, depth, true, true, <<current::binary, ?\\>>, acc)
  end

  defp do_split(<<?", rest::binary>>, depth, true, false, current, acc) do
    do_split(rest, depth, false, false, <<current::binary, ?">>, acc)
  end

  defp do_split(<<?", rest::binary>>, depth, false, _esc, current, acc) do
    do_split(rest, depth, true, false, <<current::binary, ?">>, acc)
  end

  defp do_split(<<c::utf8, rest::binary>>, depth, false, _esc, current, acc)
       when c == ?{ or c == ?[ do
    do_split(rest, depth + 1, false, false, <<current::binary, c::utf8>>, acc)
  end

  defp do_split(<<c::utf8, rest::binary>>, depth, false, _esc, current, acc)
       when c == ?} or c == ?] do
    do_split(rest, depth - 1, false, false, <<current::binary, c::utf8>>, acc)
  end

  defp do_split(<<?,, rest::binary>>, 0, false, _esc, current, acc) do
    do_split(rest, 0, false, false, "", [current | acc])
  end

  defp do_split(<<c::utf8, rest::binary>>, depth, in_str, _esc, current, acc) do
    do_split(rest, depth, in_str, false, <<current::binary, c::utf8>>, acc)
  end

  defp decode_scalar(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "null" -> nil
      trimmed == "true" -> true
      trimmed == "false" -> false
      String.starts_with?(trimmed, "\"") -> Jason.decode!(trimmed)
      true -> parse_number(trimmed)
    end
  end

  defp parse_number(text) do
    case Integer.parse(text) do
      {int, ""} -> int
      _ -> parse_float(text)
    end
  end

  defp parse_float(text) do
    case Float.parse(text) do
      {float, ""} -> float
      _ -> text
    end
  end
end
