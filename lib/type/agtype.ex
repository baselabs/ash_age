defmodule AshAge.Type.Agtype do
  @moduledoc """
  AGType decoder for PostgreSQL AGE graph data.

  AGE returns text in formats like:

      {"id": 844424930131969, "label": "Person", "properties": {"name": "Usman"}}::vertex
      {"id": N, "label": "L", "end_id": N, "start_id": N, "properties": {...}}::edge
      [vertex, edge, vertex, ...]::path

  This module strips the type suffix, JSON-decodes the body, and maps to the
  appropriate struct.
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

  defp decode_path(json) do
    elements = Jason.decode!(json)

    {vertices, edges} =
      elements
      |> Enum.with_index()
      |> Enum.split_with(fn {_el, idx} -> rem(idx, 2) == 0 end)

    vertex_structs =
      Enum.map(vertices, fn {v, _idx} ->
        %Vertex{
          id: v["id"],
          label: v["label"],
          properties: v["properties"] || %{}
        }
      end)

    edge_structs =
      Enum.map(edges, fn {e, _idx} ->
        %Edge{
          id: e["id"],
          label: e["label"],
          start_id: e["start_id"],
          end_id: e["end_id"],
          properties: e["properties"] || %{}
        }
      end)

    %Path{vertices: vertex_structs, edges: edge_structs}
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
