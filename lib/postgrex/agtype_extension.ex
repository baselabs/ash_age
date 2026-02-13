defmodule AshAge.Postgrex.AgtypeExtension do
  @moduledoc """
  Postgrex extension for AGE agtype.
  """

  import Postgrex.BinaryUtils, warn: false

  def init(opts), do: Keyword.get(opts, :decode_binary, :copy)

  def matching(_), do: [type: "agtype"]

  def format(_), do: :text

  def encode(_) do
    quote location: :keep do
      value when is_binary(value) ->
        [<<byte_size(value)::int32()>> | value]

      other ->
        raise DBConnection.EncodeError,
              Postgrex.Utils.encode_msg(other, "a binary")
    end
  end

  def decode(:copy) do
    quote location: :keep do
      <<len::int32(), value::binary-size(len)>> ->
        :binary.copy(value)
    end
  end

  def decode(_) do
    quote location: :keep do
      <<len::int32(), value::binary-size(len)>> ->
        value
    end
  end
end
