defmodule AgentLink.Frame do
  @moduledoc """
  One JSON-RPC object on the wire.

  Stdio is one object per line. The agent relay and the uplink put one object
  in each text frame, with no trailing newline required. A JSON array, a bare
  value, or a broken line is not a message.

  `AgentLink.Plane.client_frame/2` and `AgentLink.Plane.agent_frame/2` do not
  use this codec. They split lines within one text message and keep no
  remainder. `client_frame/2` answers a JSON-RPC batch with -32600.
  """

  @type item :: {:ok, map} | {:error, binary}

  @doc """
  Take complete stdio messages out of `buffer <> chunk`.

  Each JSON object is `{:ok, message}`. A non-empty line that is not one JSON
  object is `{:error, line}`. Blank lines are skipped. Invalid UTF-8 is not
  trimmed and is `{:error, line}`. The rest is an incomplete line, still
  buffered, including any leading space or invalid bytes.
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
    if String.valid?(line) do
      case decode(line) do
        {:ok, message} -> {:ok, message}
        :error -> {:error, line}
      end
    else
      {:error, line}
    end
  end

  defp split(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        split(rest, keep(line, acc))

      _ ->
        {Enum.reverse(acc), buffer}
    end
  end

  # String.trim/1 raises ArgumentError on invalid UTF-8. A broken line is an
  # error, so those bytes stay whole for the caller to log.
  defp keep(line, acc) do
    if String.valid?(line) do
      case String.trim(line) do
        "" -> acc
        line -> [line | acc]
      end
    else
      [line | acc]
    end
  end
end
