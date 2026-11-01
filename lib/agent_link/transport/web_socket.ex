defmodule AgentLink.Transport.WebSocket do
  @moduledoc """
  Production behaviour. Mint owns the HTTP upgrade and the WebSocket frame
  codec. A `wss` URL dials TLS. Mint checks the peer certificate against the
  system CA store.

  `AgentLink.Uplink` still dials on its own. It does not call this module.
  """

  @behaviour AgentLink.Transport
  use GenServer
  require Logger

  @connect_timeout 3_000

  # Failed dials wait this long. Tests may pass a longer `:backoff`.
  # Anything under 50ms is raised so a refused dial cannot tight-loop.
  @min_backoff 50

  defstruct [
    :owner,
    :url,
    :headers,
    :backoff,
    :default_path,
    :conn,
    :websocket,
    :ref,
    :timer,
    :connect_token,
    outbox: [],
    held: false
  ]

  @doc """
  Dial `url`. The owner receives `{:from_plane, message}` and
  `{:transport_closed, code, reason}`.

  `:owner` and `:url` are required. `:headers` defaults to
  `AgentLink.Auth.headers/0`. `:default_path` is used when `url` has no path,
  default `/agent`.
  """
  @impl true
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      owner: Keyword.fetch!(opts, :owner),
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.get_lazy(opts, :headers, &AgentLink.Auth.headers/0),
      backoff: retry_delay(Keyword.get(opts, :backoff, 500)),
      default_path: Keyword.get(opts, :default_path, "/agent")
    }

    {:ok, request_connect(state, 0)}
  end

  @doc "One ACP object toward the plane. Queued when the socket is down."
  @impl true
  def send_message(server, message) when is_map(message) do
    GenServer.cast(server, {:send, message})
    :ok
  end

  @impl true
  def handle_cast({:send, message}, state) do
    was_up = up?(state)
    state = transmit(message, state)

    if was_up and not up?(state) do
      schedule(state)
    else
      {:noreply, state}
    end
  end

  @doc "Stop the next dial. An open socket stays up until the peer closes it."
  @impl true
  def hold(server), do: GenServer.call(server, :hold)

  @doc """
  Queue a dial to `url`. Clears a hold. Returns once the dial is queued, not
  once the socket is up. The owner is not told that this process closed the
  previous socket.
  """
  @impl true
  def reconnect(server, url) when is_binary(url), do: GenServer.call(server, {:reconnect, url})

  @impl true
  def handle_call(:hold, _from, state) do
    state = %{cancel_timer(state) | held: true, connect_token: nil}
    {:reply, :ok, state}
  end

  def handle_call({:reconnect, url}, _from, state) do
    # Close before queueing the dial. A frame already in the mailbox then
    # sees no socket and cannot replace this dial.
    close_quietly(state)

    state = %{
      cancel_timer(state)
      | held: false,
        url: url,
        conn: nil,
        websocket: nil,
        ref: nil
    }

    {:reply, :ok, request_connect(state, 0)}
  end

  @impl true
  def handle_info({:connect, token}, %{connect_token: token, held: false} = state) do
    connect(%{state | timer: nil, connect_token: nil})
  end

  def handle_info({:connect, _token}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &apply_response/2)
        if up?(state), do: {:noreply, state}, else: schedule(state)

      {:error, conn, reason, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &apply_response/2)

        # A close frame is its own data message and is decoded above, or in
        # `responses`. 1006 is a socket that died with nothing left to decode.
        state =
          if up?(state) do
            Logger.warning("transport error #{inspect(reason)}")
            fail(state, 1006, reason)
          else
            close_quietly(state)
            %{state | conn: nil, websocket: nil, ref: nil}
          end

        schedule(state)

      :unknown ->
        {:noreply, state}
    end
  end

  # `reconnect/2` has already closed this socket. A late frame must not
  # cancel the dial that call queued.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_quietly(state)
    :ok
  end

  defp connect(state) do
    close_quietly(state)
    state = %{state | conn: nil, websocket: nil, ref: nil}

    case dial(state) do
      {:ok, state} ->
        state = flush(state)
        if up?(state), do: {:noreply, state}, else: schedule(state)

      {:error, reason, state} ->
        Logger.warning("transport connect failed #{inspect(reason)}")
        schedule(state)
    end
  end

  defp dial(state) do
    {ws_scheme, http_scheme, host, port, path} =
      AgentLink.Transport.endpoint(state.url, state.default_path)

    case Mint.HTTP.connect(http_scheme, host, port,
           protocols: [:http1],
           mode: :passive,
           timeout: @connect_timeout
         ) do
      {:ok, conn} -> upgrade(conn, ws_scheme, path, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp upgrade(conn, ws_scheme, path, state) do
    with {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, state.headers),
         {:ok, conn, responses} <- await_upgrade(conn, ref, []),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(conn, ref, status_of(responses, ref), headers_of(responses, ref)) do
      state = %{state | conn: conn, websocket: websocket, ref: ref}

      # Active before the early frames. A failed set_mode then never delivers
      # a frame the owner would see without a following transport_closed.
      case Mint.HTTP.set_mode(conn, :active) do
        {:ok, conn} ->
          state = decode_early(%{state | conn: conn}, early_data(responses, ref))
          if up?(state), do: Logger.info("transport connected #{state.url}")
          {:ok, state}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason, %{state | conn: nil, websocket: nil, ref: nil}}
      end
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason, state}

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)
        {:error, reason, state}
    end
  end

  defp await_upgrade(conn, ref, acc) do
    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      status = status_of(acc, ref)

      if status == 101 do
        {:ok, conn, acc}
      else
        {:error, conn, {:status, status}}
      end
    else
      case Mint.HTTP.recv(conn, 0, @connect_timeout) do
        {:ok, conn, responses} -> await_upgrade(conn, ref, acc ++ responses)
        other -> other
      end
    end
  end

  # Mint treats bytes after the 101 as the response body. They are already
  # off the socket, so they are decoded after set_mode from this list.
  defp early_data(responses, ref) do
    for {:data, ^ref, data} <- responses, do: data
  end

  defp decode_early(state, chunks) do
    Enum.reduce(chunks, state, fn data, state ->
      if up?(state), do: apply_response({:data, state.ref, data}, state), else: state
    end)
  end

  defp status_of(responses, ref) do
    Enum.find_value(responses, fn
      {:status, ^ref, status} -> status
      _ -> nil
    end)
  end

  defp headers_of(responses, ref) do
    Enum.find_value(responses, [], fn
      {:headers, ^ref, headers} -> headers
      _ -> nil
    end)
  end

  defp apply_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when not is_nil(websocket) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &apply_frame/2)

      {:error, websocket, reason} ->
        Logger.warning("transport decode failed #{inspect(reason)}")
        fail(%{state | websocket: websocket}, 1002, reason)
    end
  end

  defp apply_response(_response, state), do: state

  defp apply_frame(_frame, %{websocket: nil} = state), do: state
  defp apply_frame({:text, payload}, state), do: forward(payload, state)
  defp apply_frame({:binary, payload}, state), do: forward(payload, state)
  defp apply_frame({:ping, payload}, state), do: send_frame(state, {:pong, payload})
  defp apply_frame({:pong, _payload}, state), do: state

  defp apply_frame({:close, code, reason}, state) do
    # 1005 means the frame carried no status code. A nil reason is empty.
    fail(state, code || 1005, reason || "")
  end

  defp apply_frame({:error, reason}, state) do
    Logger.warning("transport frame error #{inspect(reason)}")
    fail(state, 1002, reason)
  end

  defp apply_frame(_frame, state), do: state

  defp forward(payload, state) do
    case AgentLink.Frame.decode(payload) do
      {:ok, message} -> send(state.owner, {:from_plane, message})
      :error -> :ok
    end

    state
  end

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, conn, reason} ->
            Logger.warning("transport send failed #{inspect(reason)}")
            # 1006 is abnormal closure: the socket died without a close frame.
            fail(%{state | conn: conn}, 1006, reason)
        end

      {:error, websocket, reason} ->
        Logger.warning("transport encode failed #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp transmit(message, state) do
    if up?(state) do
      state = send_frame(state, {:text, AgentLink.Frame.encode(message)})
      if up?(state), do: state, else: enqueue(state, message)
    else
      enqueue(state, message)
    end
  end

  # Newest first. `flush/1` reverses so the plane sees the earlier object first.
  defp enqueue(state, message), do: %{state | outbox: [message | state.outbox]}

  defp flush(%{outbox: []} = state), do: state

  defp flush(state) do
    flush_pending(Enum.reverse(state.outbox), %{state | outbox: []})
  end

  defp flush_pending([], state), do: state

  defp flush_pending([message | rest], state) do
    state = transmit(message, state)

    if up?(state) do
      flush_pending(rest, state)
    else
      %{state | outbox: Enum.reverse(rest) ++ state.outbox}
    end
  end

  defp fail(%{websocket: nil} = state, _code, _reason) do
    close_quietly(state)
    %{state | conn: nil, websocket: nil, ref: nil}
  end

  defp fail(state, code, reason) do
    close_quietly(state)
    send(state.owner, {:transport_closed, normalize_code(code), close_reason(reason)})
    %{state | conn: nil, websocket: nil, ref: nil}
  end

  defp normalize_code(code) when is_integer(code) and code >= 0, do: code
  defp normalize_code(_code), do: 1005

  defp close_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp close_reason(reason) when is_binary(reason), do: reason
  defp close_reason(nil), do: ""
  defp close_reason(reason), do: inspect(reason)

  defp schedule(%{held: true} = state) do
    {:noreply, %{cancel_timer(state) | connect_token: nil}}
  end

  defp schedule(state), do: {:noreply, request_connect(state, state.backoff)}

  # `send/2` puts the dial in the mailbox before this call returns, so
  # `reconnect/2` has queued the dial by the time it replies. A timer can
  # still be cancelled by hold.
  defp request_connect(state, delay) when delay <= 0 do
    state = cancel_timer(state)
    token = make_ref()
    send(self(), {:connect, token})
    %{state | timer: nil, connect_token: token}
  end

  defp request_connect(state, delay) do
    state = cancel_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:connect, token}, delay)
    %{state | timer: timer, connect_token: token}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp retry_delay(delay) when is_integer(delay) and delay >= @min_backoff, do: delay
  defp retry_delay(_delay), do: @min_backoff

  defp up?(%{websocket: websocket}), do: not is_nil(websocket)

  defp close_quietly(%{conn: conn}) when not is_nil(conn), do: Mint.HTTP.close(conn)
  defp close_quietly(_state), do: :ok
end
