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
  frame is code 1006. `hold/1` stops the next dial, which is how the uplink
  parks on close codes 4001–4004. Call it from the `transport_closed` handler:
  the pending dial is cancelled before `hold/1` returns. `release/1` clears
  that hold and dials when the socket is down. An open socket stays up.
  `reconnect/2` dials a new URL now and clears a hold. That dial does not
  report `transport_closed` for the socket it closes itself.

  `:backoff` is a fixed delay in milliseconds, default 500, not an exponential
  series. `:headers` defaults to `AgentLink.Auth.headers/0`. `:default_path`
  is used when the URL has no path, default `/agent`. The client relay passes
  `/acp`.

  `endpoint/2` is the URL parser both relays share. It is not a callback.
  `AgentLink.Uplink` still dials on its own.
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

  `:headers` defaults to `AgentLink.Auth.headers/0`. `:backoff` is the
  reconnect delay in milliseconds, default 500. `:default_path` is used when
  `:url` has no path, default `/agent`.
  """
  @callback start_link(keyword) :: GenServer.on_start()

  @doc "One ACP object toward the plane. Queued when the socket is down."
  @callback send_message(server :: term, message :: map) :: :ok

  @doc "Stop the next dial. An open socket stays up until the peer closes it."
  @callback hold(server :: term) :: :ok

  @doc "Clear the hold. Dial now when the socket is down."
  @callback release(server :: term) :: :ok

  @doc """
  Dial `url` now. Clears a hold. The owner is not told that this process
  closed the previous socket.
  """
  @callback reconnect(server :: term, url :: String.t()) :: :ok

  @doc """
  The socket scheme, HTTP scheme, host, port, and path for a plane URL.

  `wss` and `https` use TLS. A missing port is 443 for those and 80 otherwise.
  A missing host is `127.0.0.1`. A missing path is `default_path`. The client
  relay passes `/acp`. The uplink passes `/agent`.
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
