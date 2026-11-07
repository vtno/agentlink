defmodule AgentLink.Relay.Client do
  @moduledoc """
  Copies ACP between an editor on stdio and the plane.

  Startup sends `runtime/list`, calls `AgentLink.Relay.Target.select/2` with
  the runtime names in the order the plane returned them, then sends
  `runtime/select`. Those two requests use the ids `"agentlink:runtime/list"`
  and `"agentlink:runtime/select"`. Their responses are not written to the
  editor. Editor bytes that arrive before `runtime/select` answers stay in
  order and are copied after that answer.

  A bad target, a runtime error, or a `runtime/list` result that is not a
  list of objects with a binary `name` stops this process with
  `{:shutdown, message}`. `child_spec/1` uses `restart: :transient`, so a
  supervisor does not start it again. A closed plane socket while one of
  those requests is in flight sends that request again. The transport dials
  again on its own. After `runtime/select` succeeds, a closed plane socket
  calls `hold/1` and stops this process with `{:shutdown, "plane closed"}`.

  After `runtime/select` succeeds, each ACP message is copied unchanged,
  except an `initialize` result. That result sets
  `agentCapabilities.loadSession` to true. `sessionCapabilities` gains
  `list`, `resume`, and `close`. A value that is already a map stays. Any
  other capability stays. `session/list`, `session/load`, `session/resume`,
  and `session/close` are copied through. The plane answers them.

  `AgentLink.Application` does not start this process.
  """

  use GenServer
  require Logger

  @list_id "agentlink:runtime/list"
  @select_id "agentlink:runtime/select"
  @session_keys ["list", "resume", "close"]
  @dropped_bytes 80

  defstruct [
    :transport,
    :transport_pid,
    :stdio,
    :stdio_term,
    :target,
    :selected,
    buffer: "",
    phase: :list,
    startup_ids: MapSet.new(),
    from_editor: [],
    from_plane: [],
    initialize_ids: MapSet.new()
  ]

  @doc """
  Child spec for a supervisor.

  `restart: :transient`, so a supervisor does not start this process again
  after `{:shutdown, message}`. The supervisor starts it again after a crash.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Start the client relay.

  `:plane` is the plane URL and is required. `:token` is the bearer token.
  Omitted, nil, or `""` sends no `Authorization` header. This does not read
  `AgentLink.Auth.headers/0`. `:target` is the agent name, or nil. `:transport`
  defaults to `AgentLink.Transport.WebSocket`. `:stdio` defaults to
  `AgentLink.Stdio.Console`.

  The dial passes `default_path: "/acp"`. A URL that already has a path keeps
  that path, which is `AgentLink.Transport.endpoint/2`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    plane!(opts)
    token!(opts)
    target!(opts)
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    plane = plane!(opts)
    token = token!(opts)
    target = target!(opts)
    transport = Keyword.get(opts, :transport, AgentLink.Transport.WebSocket)
    stdio = Keyword.get(opts, :stdio, AgentLink.Stdio.Console)

    case stdio.open(self()) do
      {:ok, stdio_term} ->
        open_transport(transport, stdio, stdio_term, plane, token, target)

      {:error, reason} ->
        message = "stdio open failed: #{inspect(reason)}"
        Logger.error(message)
        {:stop, {:shutdown, message}}
    end
  end

  @impl true
  def handle_info({term, {:data, data}}, %__MODULE__{stdio_term: term} = state)
      when is_binary(data) do
    {items, rest} = AgentLink.Frame.take(state.buffer, data)
    {:noreply, take_stdio(items, %{state | buffer: rest})}
  end

  def handle_info({term, :eof}, %__MODULE__{stdio_term: term} = state) do
    shutdown("stdio closed", state)
  end

  def handle_info({:from_plane, message}, %__MODULE__{} = state) when is_map(message) do
    case on_plane(state, message) do
      {:ok, state} -> {:noreply, state}
      {:stop, message} -> shutdown(message, state)
      :closed -> shutdown("stdio closed", state)
    end
  end

  # The request already left on the socket that closed. Send it again.
  # Messages still queued in the transport stay there until the next dial.
  # After runtime/select, that subscription died with the old client id.
  # hold/1 cancels the dial before it returns, then this process stops.
  def handle_info({:transport_closed, code, reason}, %__MODULE__{} = state)
      when is_integer(code) and is_binary(reason) do
    Logger.info("client relay plane socket closed code=#{code}")

    if state.phase == :copy do
      :ok = state.transport.hold(state.transport_pid)
      shutdown("plane closed", state)
    else
      {:noreply, send_pending(state)}
    end
  end

  def handle_info(message, %__MODULE__{} = state) do
    Logger.debug("client relay ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{stdio: stdio, stdio_term: term}) when not is_nil(term) do
    stdio.close(term)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_transport(transport, stdio, stdio_term, plane, token, target) do
    case transport.start_link(
           owner: self(),
           url: plane,
           headers: headers(token),
           default_path: "/acp"
         ) do
      {:ok, pid} ->
        state = %__MODULE__{
          transport: transport,
          transport_pid: pid,
          stdio: stdio,
          stdio_term: stdio_term,
          target: target
        }

        {:ok, send_pending(state)}

      {:error, reason} ->
        stdio.close(stdio_term)
        {:stop, reason}

      :ignore ->
        stdio.close(stdio_term)
        {:stop, :ignore}
    end
  end

  defp send_pending(%{phase: :list} = state) do
    send_request(state, @list_id, "runtime/list", %{})
  end

  defp send_pending(%{phase: :select} = state) do
    send_request(state, @select_id, "runtime/select", %{"name" => state.selected})
  end

  defp send_request(state, id, method, params) do
    :ok =
      state.transport.send_message(state.transport_pid, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    %{state | startup_ids: MapSet.put(state.startup_ids, id)}
  end

  defp on_plane(state, message) do
    cond do
      startup_reply?(state, message) ->
        on_startup(message, state)

      startup_duplicate?(state, message) ->
        {:ok, state}

      state.phase == :copy ->
        to_editor(state, message)

      true ->
        {:ok, %{state | from_plane: state.from_plane ++ [message]}}
    end
  end

  defp startup_reply?(%{phase: :list}, %{"id" => @list_id} = message), do: response?(message)
  defp startup_reply?(%{phase: :select}, %{"id" => @select_id} = message), do: response?(message)
  defp startup_reply?(_state, _message), do: false

  defp startup_duplicate?(state, %{"id" => id} = message) do
    MapSet.member?(state.startup_ids, id) and response?(message) and
      not startup_reply?(state, message)
  end

  defp startup_duplicate?(_state, _message), do: false

  defp on_startup(%{"error" => error}, _state) do
    {:stop, error_text(error)}
  end

  defp on_startup(%{"result" => result}, %{phase: :list} = state) do
    case runtime_names(result) do
      {:ok, names} ->
        case AgentLink.Relay.Target.select(state.target, names) do
          {:ok, name} ->
            Logger.info("client relay selected #{name}")
            {:ok, send_pending(%{state | phase: :select, selected: name})}

          {:error, message} ->
            {:stop, message}
        end

      :error ->
        {:stop, "runtime/list returned an unexpected result"}
    end
  end

  defp on_startup(%{"result" => _result}, %{phase: :select} = state) do
    begin_copy(state)
  end

  defp begin_copy(state) do
    plane = state.from_plane
    editor = state.from_editor
    state = %{state | phase: :copy, from_plane: [], from_editor: []}

    with {:ok, state} <- write_all(state, plane) do
      {:ok, Enum.reduce(editor, state, &forward_editor(&2, &1))}
    end
  end

  defp write_all(state, []), do: {:ok, state}

  defp write_all(state, [message | rest]) do
    case to_editor(state, message) do
      {:ok, state} -> write_all(state, rest)
      :closed -> :closed
    end
  end

  defp take_stdio([], state), do: state

  defp take_stdio([{:error, line} | rest], state) do
    Logger.warning("client relay dropped non-json stdio #{inspect(dropped_prefix(line))}")
    take_stdio(rest, state)
  end

  defp take_stdio([{:ok, message} | rest], %{phase: :copy} = state) do
    take_stdio(rest, forward_editor(state, message))
  end

  defp take_stdio([{:ok, message} | rest], state) do
    take_stdio(rest, %{state | from_editor: state.from_editor ++ [message]})
  end

  defp forward_editor(state, message) do
    state = track_initialize(state, message)
    :ok = state.transport.send_message(state.transport_pid, message)
    state
  end

  defp track_initialize(state, %{"method" => "initialize", "id" => id}) when not is_nil(id) do
    %{state | initialize_ids: MapSet.put(state.initialize_ids, id)}
  end

  defp track_initialize(state, _message), do: state

  defp to_editor(state, message) do
    {message, state} = rewrite_initialize(state, message)

    case state.stdio.write(state.stdio_term, AgentLink.Frame.encode_line(message)) do
      :ok -> {:ok, state}
      :closed -> :closed
    end
  end

  defp rewrite_initialize(state, %{"id" => id} = message) do
    if MapSet.member?(state.initialize_ids, id) and response?(message) do
      message =
        case message do
          %{"result" => result} = message -> Map.put(message, "result", advertise(result))
          message -> message
        end

      {message, %{state | initialize_ids: MapSet.delete(state.initialize_ids, id)}}
    else
      {message, state}
    end
  end

  defp rewrite_initialize(state, message), do: {message, state}

  defp advertise(result) when is_map(result) do
    caps =
      case Map.get(result, "agentCapabilities") do
        caps when is_map(caps) -> caps
        _ -> %{}
      end

    caps =
      caps
      |> Map.put("loadSession", true)
      |> Map.put("sessionCapabilities", sessions(Map.get(caps, "sessionCapabilities")))

    Map.put(result, "agentCapabilities", caps)
  end

  defp advertise(result), do: result

  defp sessions(caps) when is_map(caps) do
    Enum.reduce(@session_keys, caps, fn key, caps ->
      case Map.get(caps, key, :absent) do
        value when is_map(value) -> caps
        _ -> Map.put(caps, key, %{})
      end
    end)
  end

  defp sessions(_caps) do
    Map.new(@session_keys, &{&1, %{}})
  end

  defp runtime_names(%{"runtimes" => runtimes}) when is_list(runtimes) do
    Enum.reduce_while(runtimes, {:ok, []}, fn
      %{"name" => name}, {:ok, names} when is_binary(name) ->
        {:cont, {:ok, [name | names]}}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      :error -> :error
    end
  end

  defp runtime_names(_result), do: :error

  defp response?(message) do
    not is_nil(message["id"]) and
      (Map.has_key?(message, "result") or Map.has_key?(message, "error")) and
      not is_binary(message["method"])
  end

  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(error), do: "runtime request failed: #{inspect(error)}"

  defp headers(nil), do: []
  defp headers(""), do: []
  defp headers(token) when is_binary(token), do: [{"authorization", "Bearer " <> token}]

  defp plane!(opts) do
    case Keyword.fetch!(opts, :plane) do
      plane when is_binary(plane) -> plane
      other -> raise ArgumentError, "plane must be a binary, got: #{inspect(other)}"
    end
  end

  defp token!(opts) do
    case Keyword.get(opts, :token) do
      nil -> nil
      token when is_binary(token) -> token
      other -> raise ArgumentError, "token must be a binary or nil, got: #{inspect(other)}"
    end
  end

  defp target!(opts) do
    case Keyword.get(opts, :target) do
      nil -> nil
      target when is_binary(target) -> target
      other -> raise ArgumentError, "target must be a binary or nil, got: #{inspect(other)}"
    end
  end

  defp dropped_prefix(line) do
    binary_part(line, 0, min(@dropped_bytes, byte_size(line)))
  end

  defp shutdown(message, state) do
    Logger.error(message)
    {:stop, {:shutdown, message}, state}
  end
end
