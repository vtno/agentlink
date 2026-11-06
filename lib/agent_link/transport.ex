defmodule AgentLink.Transport do
  @moduledoc """
  The WebSocket to a plane. The uplink and the client relay dial through this
  behaviour. `AgentLink.Transport.WebSocket` is the production behaviour.
  Tests use `AgentLink.FakeTransport`.

  The owner receives `{:from_plane, message}` for one decoded JSON-RPC object
  and `{:transport_closed, code, reason}` when the peer drops the socket.
  `message` is a map. JSON bytes stay inside the behaviour, via `AgentLink.Frame`.

  A peer close is forwarded with its code and reason. A missing code is 1005
  and a missing reason is an empty binary. A socket that drops with no close
  frame is code 1006. A frame that cannot be decoded closes with 1002.
  `hold/1` stops the next dial, which is how the uplink parks on close codes
  4001–4004. Call it from the `transport_closed` handler: the pending dial is
  cancelled before `hold/1` returns. `reconnect/2` clears a hold and queues a
  dial. It returns once that dial is queued, not once the socket is up. The
  socket it closes itself does not produce `transport_closed`. `url/2`
  replaces the URL of the next dial. The backoff timer, a hold, and an open
  socket stay as they are.

  `preface/2` is sent before the outbox on every dial, including a dial this
  process starts itself. The uplink hello lives there: the plane requires
  that object to be the first frame, and a hello already written to a socket
  is not still sitting in the outbox when the next dial opens.

  `:headers` defaults to `AgentLink.Auth.headers/0`. `:default_path` is used
  when the URL has no path, default `/agent`. The client relay passes `/acp`.
  A failed dial waits 500ms before the next one.

  `endpoint/2` is the URL parser both relays share. It is not a callback.
  `AgentLink.Uplink` and `AgentLink.Relay.Client` dial through this behaviour.
  """

  @type endpoint :: {
          :ws | :wss,
          :http | :https,
          host :: String.t(),
          port :: pos_integer(),
          path :: String.t()
        }

  @doc """
  Dial the plane. `:owner` and `:url` are required.

  `:headers` defaults to `AgentLink.Auth.headers/0`. `:default_path` is used
  when `:url` has no path, default `/agent`. `:preface` is the map sent
  before the outbox on every dial, including the first. `:backoff` is
  milliseconds, default 500.
  """
  @callback start_link(keyword) :: GenServer.on_start()

  @doc "One ACP object toward the plane. Queued when the socket is down."
  @callback send_message(server :: term, message :: map) :: :ok

  @doc "Stop the next dial. An open socket stays up until the peer closes it."
  @callback hold(server :: term) :: :ok

  @doc """
  Queue a dial to `url`. Clears a hold. Returns once the dial is queued, not
  once the socket is up. The owner is not told that this process closed the
  previous socket.
  """
  @callback reconnect(server :: term, url :: String.t()) :: :ok

  @doc """
  Send `message` before the outbox on every dial this process opens, including
  a dial it starts itself. `nil` clears it. The socket that is already open
  is left as it is: `reconnect/2` is what opens the next one.
  """
  @callback preface(server :: term, message :: map | nil) :: :ok

  @doc """
  Use `url` for the next dial, including a dial this process starts itself.
  The backoff timer, a hold, and an open socket stay as they are.
  `reconnect/2` is what cancels the timer and dials now.
  """
  @callback url(server :: term, url :: String.t()) :: :ok

  @doc """
  The socket scheme, HTTP scheme, host, port, and path for a plane URL.

  `wss` and `https` use TLS. A missing port is 443 for those and 80 otherwise.
  A missing host is `127.0.0.1`. A missing path is `default_path`. The client
  relay passes `/acp`. The uplink passes `/agent`. The query string is ignored.
  Auth goes through the request headers.
  """
  @spec endpoint(String.t(), String.t()) :: endpoint
  def endpoint(url, default_path) when is_binary(url) and is_binary(default_path) do
    uri = URI.parse(url)
    secure = uri.scheme in ["wss", "https"]
    port = uri.port || if(secure, do: 443, else: 80)

    {
      if(secure, do: :wss, else: :ws),
      if(secure, do: :https, else: :http),
      uri.host || "127.0.0.1",
      port,
      uri.path || default_path
    }
  end
end
