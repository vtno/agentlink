defmodule AgentLink.Frame do
  @moduledoc """
  One JSON-RPC object on the wire.

  Stdio is one object per line. A plane socket is one object per text frame,
  with no trailing newline required. The agent relay and the uplink share this
  codec. A JSON array, a bare value, or a broken line is not a message.

  The plane parses client frames itself. One client frame may be a JSON-RPC
  batch, and the plane answers that with its own error.
  """

  @type item :: {:ok, map} | {:error, binary}

  @doc """
  Take complete stdio messages out of `buffer <> chunk`.

  Each JSON object is `{:ok, message}`. A non-empty line that is not one JSON
  object is `{:error, line}`. Blank lines are skipped. The rest is an
  incomplete line, still buffered, including any leading space.
  """
  @spec take(buffer :: binary, chunk :: binary) :: {[item], rest :: binary}
  def take(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    {lines, rest} = split(buffer <> chunk, [])
    {Enum.map(lines, &decode_line/1), rest}
  end

  @doc "One ACP message as a stdio line, including the newline."
  @spec encode_line(map) :: iodata
  def encode_line(message) when is_map(message), do: [encode(message), ?\n]

  @doc """
  One WebSocket text or binary payload. A single JSON object, or `:error`.
  Trailing whitespace is part of that one object. A second value is an error.
  """
  @spec decode(binary) :: {:ok, map} | :error
  def decode(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, message} when is_map(message) -> {:ok, message}
      _ -> :error
    end
  end

  @doc "One ACP message as a WebSocket text payload. No trailing newline."
  @spec encode(map) :: binary
  def encode(message) when is_map(message), do: Jason.encode!(message)

  defp decode_line(line) do
    case decode(line) do
      {:ok, message} -> {:ok, message}
      :error -> {:error, line}
    end
  end

  defp split(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        line = String.trim(line)
        acc = if line == "", do: acc, else: [line | acc]
        split(rest, acc)

      _ ->
        {Enum.reverse(acc), buffer}
    end
  end
end
