defmodule AshAge.Postgrex.AgtypeExtension do
  @moduledoc """
  Postgrex extension for AGE agtype.
  """

  import Postgrex.BinaryUtils, warn: false

  def init(opts), do: Keyword.get(opts, :decode_binary, :copy)

  def matching(_), do: [type: "agtype"]

  def format(_), do: :text

  def encode(_) do
    quote do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        :error
    end
  end

  def decode(:copy) do
    quote do
      value when is_binary(value) ->
        :binary.copy(value)

      value ->
        value
    end
  end

  def decode(_) do
    quote do
      value -> value
    end
  end
end
