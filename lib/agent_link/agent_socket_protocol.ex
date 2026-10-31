defmodule AgentLink.AgentSocketProtocol do
  @moduledoc """
  The agent WebSocket handshake protocol shared by `AgentLink.AgentSocket` and `AgentLink.Uplink`.
  The relay registers with an `agentlink.uplink` hello. This does not cover the client socket.

  Private-use WebSocket codes (RFC 6455) identify permanent rejections:
  4001 name taken, 4002 instance too long, 4003 bad name, 4004 not allowed.
  All park the relay. Only 4002 stays parked across link target changes;
  the others permit a new dial when the name or plane URL changes.
  Other closes are transient and the relay retries after 500ms.
  """

  # Stock relays send 16 random bytes as unpadded base64url, which is 22 bytes.
  # 128 leaves room for a longer token without storing an unbounded id.
  @max_instance_bytes 128

  @type rejection :: :name_taken | :instance_too_long | :bad_name | :not_allowed

  @doc "The longest relay instance id accepted in a hello, in bytes."
  def max_instance_bytes, do: @max_instance_bytes

  @doc "The permanent rejection carried by this close code, or nil for a transient close."
  @spec rejection(integer()) :: rejection() | nil
  def rejection(4001), do: :name_taken
  def rejection(4002), do: :instance_too_long
  def rejection(4003), do: :bad_name
  def rejection(4004), do: :not_allowed
  def rejection(_code), do: nil

  @doc "The private-use WebSocket close code for a permanent rejection."
  @spec close_code(rejection()) :: integer()
  def close_code(:name_taken), do: 4001
  def close_code(:instance_too_long), do: 4002
  def close_code(:bad_name), do: 4003
  def close_code(:not_allowed), do: 4004

  @doc "A wire-safe close reason, also used when the plane sends no reason text."
  @spec reason(rejection(), String.t() | nil) :: String.t()
  def reason(rejection, name \\ nil)

  def reason(:name_taken, name) when is_binary(name) do
    ~s(name "#{name}" is in use; stop the other relay or change name)
  end

  def reason(:name_taken, _name), do: "name is in use; stop the other relay or change name"

  def reason(:instance_too_long, _name) do
    "instance id is too long; max is #{@max_instance_bytes} bytes"
  end

  def reason(:bad_name, _name), do: "link name must be a short slug"
  def reason(:not_allowed, _name), do: "uplink is not allowed"
end
