defmodule AgentLink.Uplink do
  @moduledoc """
  Dials the plane's agent socket. Outbound text frames are one JSON object
  from `AgentLink.Frame`. Mint owns the HTTP upgrade and the WebSocket frame
  codec. Nothing here calls the plane process directly. A `wss` plane URL
  dials TLS. Mint checks the peer certificate against the system CA store.

  A dropped socket redials. The hello carries this VM's relay instance, so
  the plane can release this relay's previous socket when this process dials
  again. A close that means this name is already in use logs the clash and
  waits until the link name or plane URL changes. A close that means the
  instance id is too long logs the error and does not redial until restart.
  Bad-name and not-allowed closes also park until the name or plane URL changes
  or the relay restarts. The codes and reasons are shared in `AgentLink.AgentSocketProtocol`.
  """

  use GenServer
  require Logger

  defstruct [
    :owner,
    :conn,
    :websocket,
    :ref,
    :link,
    outbox: [],
    rejection: nil
  ]

  @doc "Dial the plane's agent socket. A remote relay never calls the plane process directly."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    case read_link() do
      {:ok, link} ->
        send(self(), :connect)
        Process.send_after(self(), :watch, 1_000)
        {:ok, %__MODULE__{owner: Keyword.fetch!(opts, :owner), link: link}}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @doc "One ACP object toward the plane. Queued if the socket is down."
  def send_message(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:send, message})
  end

  @impl true
  def handle_cast({:send, message}, %__MODULE__{} = state) do
    was_up = not is_nil(state.websocket)
    state = transmit(message, state)

    if was_up and is_nil(state.websocket) do
      schedule(state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect, %__MODULE__{rejection: rejection} = state) when not is_nil(rejection),
    do: {:noreply, state}

  def handle_info(:connect, %__MODULE__{} = state) do
    close_conn(state)

    case read_link() do
      {:ok, link} ->
        connect(link, state)

      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info(:watch, %__MODULE__{} = state) do
    case read_link() do
      {:ok, link} ->
        state = maybe_redial(state, link)
        Process.send_after(self(), :watch, 1_000)
        {:noreply, state}

      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info(message, %__MODULE__{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &apply_response/2)
        if state.conn, do: {:noreply, state}, else: schedule(state)

      {:error, conn, reason, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &apply_response/2)
        unless parked?(state), do: Logger.warning("uplink error #{inspect(reason)}")
        close_conn(state)
        schedule(%{state | conn: nil, websocket: nil, ref: nil})

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_response({:data, ref, data}, %__MODULE__{ref: ref, websocket: websocket} = state)
       when not is_nil(websocket) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &apply_frame/2)

      {:error, websocket, reason} ->
        Logger.warning("uplink decode failed #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp apply_response(_response, state), do: state

  defp apply_frame({:text, payload}, state), do: forward_text(payload, state)
  defp apply_frame({:binary, payload}, state), do: forward_text(payload, state)

  defp apply_frame({:ping, payload}, state) do
    send_frame(state, {:pong, payload})
  end

  defp apply_frame({:close, code, reason}, state) do
    close_conn(state)
    state = %{state | conn: nil, websocket: nil, ref: nil}

    case AgentLink.AgentSocketProtocol.rejection(code) do
      nil ->
        state

      rejection ->
        log_rejection(state, rejection, reason)
        %{state | rejection: rejection}
    end
  end

  defp apply_frame({:error, reason}, state) do
    Logger.warning("uplink frame error #{inspect(reason)}")
    state
  end

  defp apply_frame(_frame, state), do: state

  defp forward_text(payload, state) do
    case AgentLink.Frame.decode(payload) do
      {:ok, message} -> send(state.owner, {:from_plane, message})
      :error -> :ok
    end

    state
  end

  defp send_frame(%__MODULE__{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, conn, reason} ->
            Logger.warning("uplink send failed #{inspect(reason)}")
            Mint.HTTP.close(conn)
            %{state | conn: nil, websocket: nil, ref: nil}
        end

      {:error, websocket, reason} ->
        Logger.warning("uplink encode failed #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp upgrade(conn, ws_scheme, path) do
    with {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, AgentLink.Auth.headers()),
         {:ok, conn, status, headers} <- await_upgrade(conn, ref, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, ref, websocket}
    else
      {:error, conn, reason} -> {:error, conn, reason}
      {:error, conn, reason, _responses} -> {:error, conn, reason}
    end
  end

  defp await_upgrade(conn, ref, acc) do
    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      status = status_of(acc, ref)

      if status == 101 do
        {:ok, conn, status, headers_of(acc, ref)}
      else
        {:error, conn, {:status, status}}
      end
    else
      case Mint.HTTP.recv(conn, 0, 3_000) do
        {:ok, conn, responses} -> await_upgrade(conn, ref, acc ++ responses)
        other -> other
      end
    end
  end

  defp read_link do
    case AgentLink.Link.read() do
      {:ok, link} ->
        {:ok, link}

      {:error, message} ->
        Logger.error(message)
        {:stop, {:shutdown, message}}
    end
  end

  @doc """
  The socket scheme, HTTP scheme, host, port, and path for a plane URL.
  `wss` and `https` use TLS. A missing port is 443 for those and 80 otherwise.
  A missing path is `/agent`.
  """
  def endpoint(url) do
    uri = URI.parse(url)
    secure = uri.scheme in ["wss", "https"]
    port = uri.port || if(secure, do: 443, else: 80)

    {
      if(secure, do: :wss, else: :ws),
      if(secure, do: :https, else: :http),
      uri.host || "127.0.0.1",
      port,
      uri.path || "/agent"
    }
  end

  defp connect(link, %__MODULE__{} = state) do
    {ws_scheme, http_scheme, host, port, path} = endpoint(link.plane_url)

    case Mint.HTTP.connect(http_scheme, host, port,
           protocols: [:http1],
           mode: :passive,
           timeout: 3_000
         ) do
      {:ok, conn} ->
        case upgrade(conn, ws_scheme, path) do
          {:ok, conn, ref, websocket} ->
            Logger.info("uplink connected #{link.plane_url}")
            state = %{state | conn: conn, websocket: websocket, ref: ref, link: link}
            state = transmit(uplink_hello(link), state)

            cond do
              is_nil(state.conn) ->
                schedule(state)

              true ->
                case Mint.HTTP.set_mode(state.conn, :active) do
                  {:ok, conn} ->
                    {:noreply, flush(%{state | conn: conn})}

                  {:error, conn, reason} ->
                    Logger.warning("uplink active mode failed #{inspect(reason)}")
                    Mint.HTTP.close(conn)
                    schedule(%{state | conn: nil, websocket: nil, ref: nil})
                end
            end

          {:error, conn, reason} ->
            Logger.warning("uplink handshake failed #{inspect(reason)}")
            Mint.HTTP.close(conn)
            schedule(%{state | conn: nil, websocket: nil, ref: nil})
        end

      {:error, reason} ->
        Logger.warning("uplink connect failed #{inspect(reason)}")
        schedule(%{state | conn: nil, websocket: nil, ref: nil})
    end
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

  # The plane rejected this dial for a reason that will not change on its own.
  defp schedule(%__MODULE__{} = state) do
    if parked?(state) do
      {:noreply, state}
    else
      Process.send_after(self(), :connect, 500)
      {:noreply, state}
    end
  end

  defp parked?(%__MODULE__{rejection: rejection}), do: not is_nil(rejection)

  defp maybe_redial(%__MODULE__{} = state, link) do
    cond do
      parked?(state) and state.rejection != :instance_too_long and
          link_target_changed?(state.link, link) ->
        Logger.info("agent link changed, redialing as #{link.name}")
        send(self(), :connect)
        %{state | rejection: nil}

      state.conn && link != state.link ->
        Logger.info("agent link changed, redialing as #{link.name}")
        send(self(), :connect)
        state

      true ->
        state
    end
  end

  defp link_target_changed?(current, link) do
    link.name != current.name or link.plane_url != current.plane_url
  end

  defp log_rejection(%__MODULE__{} = state, rejection, reason) do
    detail =
      if is_binary(reason) and reason != "" do
        reason
      else
        AgentLink.AgentSocketProtocol.reason(rejection, state.link.name)
      end

    action =
      case rejection do
        :name_taken ->
          "Another relay is already connected with this name. " <>
            "Stop the other relay and restart this one, or change name in #{AgentLink.Paths.link()}. "

        :bad_name ->
          "Fix name in #{AgentLink.Paths.link()} and restart this relay, or change name or plane_url. "

        :not_allowed ->
          "Ask the plane operator to allow this uplink, then restart this relay, " <>
            "or change name or plane_url in #{AgentLink.Paths.link()}. "

        :instance_too_long ->
          "Fix the relay instance id and restart this relay. "
      end

    # The instance id is not in the link file. Changing the target cannot fix it.
    wait =
      if rejection == :instance_too_long,
        do: "This relay will not reconnect until restart",
        else: "This relay will not reconnect until name or plane_url changes, or restart"

    Logger.error("uplink rejected name=#{state.link.name} #{detail}. " <> action <> wait)
  end

  defp transmit(message, %__MODULE__{websocket: nil} = state) do
    %{state | outbox: [message | state.outbox]}
  end

  defp transmit(message, state) do
    case send_frame(state, {:text, AgentLink.Frame.encode(message)}) do
      %{websocket: nil} = state -> %{state | outbox: [message | state.outbox]}
      state -> state
    end
  end

  defp flush(%__MODULE__{outbox: []} = state), do: state

  defp flush(state) do
    flush(Enum.reverse(state.outbox), %{state | outbox: []})
  end

  defp flush([], state), do: state

  defp flush([message | rest] = pending, state) do
    state = transmit(message, state)
    if state.websocket, do: flush(rest, state), else: %{state | outbox: Enum.reverse(pending)}
  end

  defp close_conn(%__MODULE__{conn: conn}) when not is_nil(conn), do: Mint.HTTP.close(conn)
  defp close_conn(_state), do: :ok

  defp uplink_hello(link) do
    %{
      "jsonrpc" => "2.0",
      "method" => "agentlink.uplink",
      "params" => %{
        "name" => link.name,
        "label" => link.label,
        "program" => link.program,
        "instance" => relay_instance()
      }
    }
  end

  # One id per VM. A new `AgentLink.Uplink` process in this BEAM is still this relay.
  # A second OS process has a different id and cannot take the name.
  defp relay_instance do
    key = {__MODULE__, :instance}

    case :persistent_term.get(key, nil) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        :persistent_term.put(key, id)
        id
    end
  end
end
