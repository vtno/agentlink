defmodule AgentLink.Client do
  @moduledoc false
  defstruct [:pid, :subject, runtime: nil, session_id: nil, capabilities: nil]
end

defmodule AgentLink.AgentSlot do
  @moduledoc false
  defstruct [
    :name,
    agent_pending: %{},
    fan_pending: %{},
    prompt_queue: :queue.new(),
    prompt_inflight: false,
    next_agent_id: 1_000_000,
    next_fan_id: 1,
    init_sent: false,
    init_cache: nil,
    init_waiters: []
  ]
end

defmodule AgentLink.Plane do
  @moduledoc """
  WebSocket proxy for ACP stdio. `initialize` is cached per agent. The agent
  sees the first client's `clientCapabilities`. Each client keeps the
  advertisement from its own `initialize`. `session/new` is forwarded. On
  success the plane calls `AgentLink.Plane.Sessions.open/5`. The plane
  answers `session/list`, `session/load`, `session/resume`, and
  `session/close` from that directory and does not forward them. A live
  `session/update` that carries a `sessionId` goes through
  `AgentLink.Plane.Sessions.broadcast/3`. Each client that has that session
  open receives it. `AgentLink.Client.session_id` is the last session that
  client opened, loaded, or resumed. Delivery of `session/update` does not
  read that field. An agent question goes only to the client whose prompt
  is in flight. `fs/read_text_file` is forwarded only when that client's
  `fs.readTextFile` is true, and `fs/write_text_file` only when
  `fs.writeTextFile` is true. `terminal/*` is forwarded only when `terminal`
  is true. Any other `fs/*` or `terminal/*` request is not forwarded. The
  plane answers the agent with JSON-RPC `-32601` and the message
  `client does not support this method`. A disconnect calls
  `AgentLink.Plane.Sessions.disconnect/1`, declines that client's outstanding
  questions, and drops its queued prompts and initialize waiters. The active
  prompt releases the slot only when the agent replies. One agent process
  runs one prompt at a time.
  """

  use GenServer

  defstruct clients: %{}, monitors: %{}, slots: %{}

  @doc "Start the named broker. One plane owns every client socket and every agent socket."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @doc "A client socket connected. Remember it and hand back its id. The subject is required."
  def register(pid, %AgentLink.Access.Subject{} = subject) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:register, pid, subject})

  @impl true
  def handle_call({:register, pid, subject}, _from, %__MODULE__{} = state) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    ref = Process.monitor(pid)

    state = %{
      state
      | clients: Map.put(state.clients, id, %AgentLink.Client{pid: pid, subject: subject}),
        monitors: Map.put(state.monitors, ref, id)
    }

    {:reply, id, state}
  end

  @doc "Text from an app. Route it as ACP from that client."
  def client_frame(client_id, text), do: GenServer.cast(__MODULE__, {:frame, client_id, text})

  @doc "Text from the agent socket. Route it as ACP from that agent."
  def agent_frame(name, text) when is_binary(name) and is_binary(text),
    do: GenServer.cast(__MODULE__, {:agent_frame, name, text})

  @doc "A new uplink registered this name. Drop the cached slot so the next app initializes it fresh."
  def runtime_reset(name) when is_binary(name),
    do: GenServer.cast(__MODULE__, {:runtime_reset, name})

  @doc "The agent socket closed. Fail whatever was still waiting on it."
  def runtime_down(name) when is_binary(name),
    do: GenServer.cast(__MODULE__, {:runtime_down, name})

  @impl true
  def handle_cast({:frame, client_id, text}, %__MODULE__{} = state) do
    state =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(state, fn line, acc ->
        case Jason.decode(line) do
          {:ok, message} when is_map(message) ->
            on_client(acc, client_id, message)

          {:ok, list} when is_list(list) ->
            push(acc, client_id, %{
              "jsonrpc" => "2.0",
              "id" => nil,
              "error" => %{"code" => -32600, "message" => "JSON-RPC batches are not supported"}
            })

          _ ->
            push(acc, client_id, %{
              "jsonrpc" => "2.0",
              "id" => nil,
              "error" => %{"code" => -32700, "message" => "parse error"}
            })
        end
      end)

    {:noreply, state}
  end

  def handle_cast({:agent_frame, name, text}, %__MODULE__{} = state) do
    state =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(state, fn line, acc ->
        case Jason.decode(line) do
          {:ok, message} when is_map(message) -> on_agent(acc, name, message)
          _ -> acc
        end
      end)

    {:noreply, state}
  end

  def handle_cast({:runtime_reset, name}, %__MODULE__{} = state),
    do: {:noreply, drop_slot(state, name, "runtime reconnected")}

  def handle_cast({:runtime_down, name}, %__MODULE__{} = state),
    do: {:noreply, drop_slot(state, name, "runtime disconnected")}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {client_id, monitors} ->
        :ok = AgentLink.Plane.Sessions.disconnect(client_id)
        slots = Map.new(state.slots, fn {name, slot} -> {name, drop_client(slot, client_id)} end)

        {:noreply,
         %{
           state
           | clients: Map.delete(state.clients, client_id),
             monitors: monitors,
             slots: slots
         }}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp on_client(%{clients: clients} = state, client_id, message)
       when is_map_key(clients, client_id) do
    cond do
      response?(message) ->
        with_runtime(state, client_id, message, &on_client_response/4)

      not is_binary(message["method"]) ->
        state

      message["method"] in ["runtime/list", "runtime/select"] ->
        on_runtime(state, client_id, message)

      message["method"] in ["session/list", "session/load", "session/resume", "session/close"] ->
        on_session(state, client_id, message)

      message["id"] == nil ->
        with_runtime(state, client_id, message, fn state, slot, _client_id, message ->
          write_agent(slot, message)
          {state, slot}
        end)

      message["method"] == "initialize" ->
        with_runtime(state, client_id, message, &on_initialize/4)

      message["method"] == "session/prompt" ->
        with_runtime(state, client_id, message, fn state, slot, client_id, message ->
          slot = %{
            slot
            | prompt_queue:
                :queue.in(%{client_id: client_id, message: message}, slot.prompt_queue)
          }

          pump(state, slot)
        end)

      true ->
        kind = if message["method"] == "session/new", do: :session_new, else: :forward

        with_runtime(state, client_id, message, fn state, slot, client_id, message ->
          forward(state, slot, client_id, message, kind)
        end)
    end
  end

  defp on_client(state, _client_id, _message), do: state

  defp on_runtime(state, client_id, %{"method" => "runtime/list", "id" => id}) do
    subject = subject_of(state, client_id)

    runtimes = AgentLink.Registry.allowed(subject)

    reply(state, client_id, id, {:ok, %{"runtimes" => runtimes}})
  end

  defp on_runtime(state, client_id, %{"method" => "runtime/select", "id" => id} = message) do
    name = get_in(message, ["params", "name"])
    subject = subject_of(state, client_id)

    cond do
      not is_binary(name) ->
        reply(state, client_id, id, {:error, "runtime name is required"})

      is_nil(AgentLink.Registry.pid(name)) ->
        reply(state, client_id, id, {:error, "runtime is not connected"})

      not AgentLink.Access.allowed?(subject, name) ->
        reply(state, client_id, id, {:error, "runtime is not allowed"})

      true ->
        clients = Map.update!(state.clients, client_id, &%{&1 | runtime: name})
        row = Enum.find(AgentLink.Registry.list(), &(&1["name"] == name))
        reply(%{state | clients: clients}, client_id, id, {:ok, row})
    end
  end

  # A runtime request without an id is a notice. Ignore it.
  defp on_runtime(state, _client_id, _message), do: state

  # These four methods are answered here. A notice has no id and is dropped.
  defp on_session(state, client_id, %{"id" => id} = message) when not is_nil(id) do
    with_runtime(state, client_id, message, fn state, slot, client_id, message ->
      case message["method"] do
        "session/list" -> on_list(state, slot, client_id, message)
        "session/load" -> on_join(state, slot, client_id, message, :load)
        "session/resume" -> on_join(state, slot, client_id, message, :resume)
        "session/close" -> on_close(state, slot, client_id, message)
      end
    end)
  end

  defp on_session(state, _client_id, _message), do: state

  defp on_list(state, slot, client_id, message) do
    case list_args(message["params"]) do
      {:ok, opts} ->
        case AgentLink.Plane.Sessions.list(slot.name, opts) do
          {:error, :invalid_cursor} ->
            {fail(state, client_id, message["id"], -32602, "invalid cursor"), slot}

          %{sessions: sessions, next_cursor: next} ->
            {reply(state, client_id, message["id"], {:ok, list_result(sessions, next)}), slot}
        end

      {:error, reason} ->
        {fail(state, client_id, message["id"], -32602, reason), slot}
    end
  end

  defp on_join(state, slot, client_id, message, mode) do
    case session_of(message) do
      session_id when is_binary(session_id) ->
        join(state, slot, client_id, message, mode, session_id)

      _ ->
        {fail(state, client_id, message["id"], -32602, "sessionId is required"), slot}
    end
  end

  defp join(state, slot, client_id, message, :load, session_id) do
    case AgentLink.Plane.Sessions.load(
           slot.name,
           session_id,
           client_id,
           client_pid(state, client_id)
         ) do
      {:ok, replay} ->
        state = Enum.reduce(replay, state, &push(&2, client_id, &1))
        {answer_join(state, slot, client_id, message, session_id), slot}

      {:error, :unknown} ->
        {fail(state, client_id, message["id"], -32002, "session not found"), slot}
    end
  end

  defp join(state, slot, client_id, message, :resume, session_id) do
    case AgentLink.Plane.Sessions.resume(
           slot.name,
           session_id,
           client_id,
           client_pid(state, client_id)
         ) do
      :ok ->
        {answer_join(state, slot, client_id, message, session_id), slot}

      {:error, :unknown} ->
        {fail(state, client_id, message["id"], -32002, "session not found"), slot}
    end
  end

  defp answer_join(state, _slot, client_id, message, session_id) do
    state = bind_session(state, client_id, session_id)
    reply(state, client_id, message["id"], {:ok, %{}})
  end

  defp on_close(state, slot, client_id, message) do
    case session_of(message) do
      session_id when is_binary(session_id) ->
        :ok = AgentLink.Plane.Sessions.leave(slot.name, session_id, client_id)
        state = release_session(state, client_id, session_id)
        {reply(state, client_id, message["id"], {:ok, %{}}), slot}

      _ ->
        {fail(state, client_id, message["id"], -32602, "sessionId is required"), slot}
    end
  end

  defp with_runtime(state, client_id, message, fun) do
    case ensure_runtime(state, client_id) do
      {:ok, state, name} ->
        slot = Map.get(state.slots, name) || new_slot(name)
        {state, slot} = fun.(state, slot, client_id, message)
        %{state | slots: Map.put(state.slots, slot.name, slot)}

      {:error, state, reason} ->
        if message["id"],
          do: reply(state, client_id, message["id"], {:error, reason}),
          else: state
    end
  end

  defp ensure_runtime(state, client_id) do
    subject = subject_of(state, client_id)

    case state.clients[client_id] do
      %{runtime: name} when is_binary(name) ->
        if AgentLink.Access.allowed?(subject, name) do
          {:ok, state, name}
        else
          {:error, state, "runtime is not allowed"}
        end

      _ ->
        case AgentLink.Registry.allowed(subject) do
          [%{"name" => name}] ->
            clients = Map.update!(state.clients, client_id, &%{&1 | runtime: name})
            {:ok, %{state | clients: clients}, name}

          [] ->
            if AgentLink.Registry.list() == [] do
              {:error, state, "no runtime connected"}
            else
              {:error, state, "runtime is not allowed"}
            end

          _ ->
            {:error, state, "select a runtime"}
        end
    end
  end

  defp subject_of(state, client_id) do
    %AgentLink.Client{subject: subject} = state.clients[client_id]
    subject
  end

  defp on_initialize(state, slot, client_id, message) do
    state = remember_capabilities(state, client_id, message)

    cond do
      slot.init_cache ->
        {send_cache(state, client_id, message["id"], slot.init_cache), slot}

      slot.init_sent ->
        {state,
         %{slot | init_waiters: slot.init_waiters ++ [%{client_id: client_id, id: message["id"]}]}}

      true ->
        slot = %{
          slot
          | init_waiters: slot.init_waiters ++ [%{client_id: client_id, id: message["id"]}]
        }

        agent_id = slot.next_agent_id
        {state, slot} = forward(state, slot, client_id, message, :initialize)

        slot =
          if Map.has_key?(slot.agent_pending, agent_id) do
            %{slot | init_sent: true}
          else
            %{slot | init_waiters: []}
          end

        {state, slot}
    end
  end

  defp remember_capabilities(state, client_id, message) do
    capabilities =
      case get_in(message, ["params", "clientCapabilities"]) do
        caps when is_map(caps) -> caps
        _ -> nil
      end

    clients = Map.update!(state.clients, client_id, &%{&1 | capabilities: capabilities})
    %{state | clients: clients}
  end

  defp forward(state, slot, client_id, message, kind) do
    agent_id = slot.next_agent_id

    case write_agent(slot, Map.put(message, "id", agent_id)) do
      :ok ->
        pending = %{
          client_id: client_id,
          client_req_id: message["id"],
          kind: kind,
          session_id: session_of(message),
          cwd: cwd_of(message)
        }

        {state,
         %{
           slot
           | next_agent_id: agent_id + 1,
             agent_pending: Map.put(slot.agent_pending, agent_id, pending)
         }}

      :down ->
        {reply(state, client_id, message["id"], {:error, "runtime is down"}), slot}
    end
  end

  defp on_agent(state, name, message) do
    slot = Map.get(state.slots, name) || new_slot(name)

    {state, slot} =
      cond do
        response?(message) and Map.has_key?(slot.agent_pending, message["id"]) ->
          {pending, agent_pending} = Map.pop(slot.agent_pending, message["id"])
          deliver(state, %{slot | agent_pending: agent_pending}, pending, message)

        is_binary(message["method"]) and not is_nil(message["id"]) ->
          ask_issuer(state, slot, message)

        true ->
          {route_notice(state, slot, message), slot}
      end

    %{state | slots: Map.put(state.slots, slot.name, slot)}
  end

  defp deliver(state, slot, %{kind: :initialize}, message) do
    cache = cache_of(message)
    ok = match?({:ok, _}, cache)
    waiters = slot.init_waiters
    slot = %{slot | init_cache: if(ok, do: cache, else: nil), init_sent: ok, init_waiters: []}

    state =
      Enum.reduce(waiters, state, fn waiter, acc ->
        send_cache(acc, waiter.client_id, waiter.id, cache)
      end)

    {state, slot}
  end

  defp deliver(state, slot, %{kind: :session_new} = pending, message) do
    cache = cache_of(message)

    state =
      case cache do
        {:ok, %{"sessionId" => session_id}} when is_binary(session_id) ->
          state = bind_session(state, pending.client_id, session_id)
          open_session(state, slot, pending, session_id)

        _ ->
          state
      end

    {reply(state, pending.client_id, pending.client_req_id, cache), slot}
  end

  defp deliver(state, slot, pending, message) do
    state = reply(state, pending.client_id, pending.client_req_id, cache_of(message))

    if pending.kind == :prompt do
      session_id = pending.session_id

      if is_binary(session_id) do
        publish(slot, session_id, %{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{"stopReason" => stop_reason(message)}
        })
      end

      pump(state, %{slot | prompt_inflight: false})
    else
      {state, slot}
    end
  end

  defp route_notice(state, slot, %{"method" => "session/update"} = message) do
    session_id = session_of(message)

    case update_of(message) do
      update when is_binary(session_id) and is_map(update) ->
        publish(slot, session_id, update)
        state

      _ ->
        fanout(state, slot, session_id, message)
    end
  end

  defp route_notice(state, slot, message) do
    fanout(state, slot, session_of(message), message)
  end

  defp ask_issuer(state, slot, message) do
    case issuer(slot, session_of(message)) do
      client_id when is_binary(client_id) ->
        case state.clients[client_id] do
          %AgentLink.Client{pid: _pid} = client ->
            if supports?(client, message["method"]) do
              fan_id = slot.next_fan_id
              state = push(state, client_id, Map.put(message, "id", fan_id))

              {state,
               %{
                 slot
                 | next_fan_id: fan_id + 1,
                   fan_pending:
                     Map.put(slot.fan_pending, fan_id, %{
                       agent_id: message["id"],
                       client_id: client_id
                     })
               }}
            else
              decline(state, slot, message, -32601, "client does not support this method")
            end

          _ ->
            decline(state, slot, message, -32000, "no app is attached to this session")
        end

      _ ->
        decline(state, slot, message, -32000, "no app is attached to this session")
    end
  end

  defp decline(state, slot, message, code, reason) do
    agent_error(slot, message["id"], code, reason)
    {state, slot}
  end

  defp agent_error(slot, id, code, reason) do
    write_agent(slot, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => reason}
    })
  end

  defp supports?(
         %AgentLink.Client{capabilities: %{"fs" => %{"readTextFile" => true}}},
         "fs/read_text_file"
       ),
       do: true

  defp supports?(
         %AgentLink.Client{capabilities: %{"fs" => %{"writeTextFile" => true}}},
         "fs/write_text_file"
       ),
       do: true

  defp supports?(%AgentLink.Client{}, "fs/" <> _), do: false

  defp supports?(%AgentLink.Client{capabilities: %{"terminal" => true}}, "terminal/" <> _),
    do: true

  defp supports?(%AgentLink.Client{}, "terminal/" <> _), do: false
  defp supports?(%AgentLink.Client{}, _method), do: true

  defp issuer(slot, session_id) do
    matches =
      Enum.filter(slot.agent_pending, fn {_id, pending} ->
        pending.kind == :prompt and session_match?(pending, session_id)
      end)

    case matches do
      [{_id, pending}] -> pending.client_id
      _ -> nil
    end
  end

  defp session_match?(_pending, nil), do: true
  defp session_match?(pending, session_id), do: pending.session_id == session_id

  defp on_client_response(state, slot, client_id, message) do
    case Map.get(slot.fan_pending, message["id"]) do
      %{client_id: owner} = fan when owner == client_id ->
        slot = %{slot | fan_pending: Map.delete(slot.fan_pending, message["id"])}

        payload =
          if message["error"] do
            %{"jsonrpc" => "2.0", "id" => fan.agent_id, "error" => message["error"]}
          else
            %{"jsonrpc" => "2.0", "id" => fan.agent_id, "result" => message["result"]}
          end

        write_agent(slot, payload)
        {state, slot}

      _ ->
        {state, slot}
    end
  end

  defp pump(state, %AgentLink.AgentSlot{prompt_inflight: true} = slot), do: {state, slot}

  defp pump(state, slot) do
    case :queue.out(slot.prompt_queue) do
      {:empty, queue} ->
        {state, %{slot | prompt_queue: queue}}

      {{:value, %{client_id: client_id}}, queue} ->
        if client_runtime(state, client_id) != slot.name do
          pump(state, %{slot | prompt_queue: queue})
        else
          dequeue(state, slot, queue)
        end
    end
  end

  defp dequeue(state, slot, queue) do
    {{:value, item}, ^queue} = :queue.out(slot.prompt_queue)
    text = prompt_text(item.message)
    session_id = session_of(item.message)
    slot = %{slot | prompt_queue: queue}

    if is_binary(session_id) and text != "" do
      publish(slot, session_id, %{
        "sessionUpdate" => "user_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })
    end

    agent_id = slot.next_agent_id
    {state, slot} = forward(state, slot, item.client_id, item.message, :prompt)

    if Map.has_key?(slot.agent_pending, agent_id) do
      {state, %{slot | prompt_inflight: true}}
    else
      pump(state, slot)
    end
  end

  defp drop_client(slot, client_id) do
    {orphaned, remaining} =
      Enum.split_with(slot.fan_pending, fn {_id, fan} -> fan.client_id == client_id end)

    Enum.each(orphaned, fn {_id, fan} ->
      agent_error(slot, fan.agent_id, -32000, "no app is attached to this session")
    end)

    # Keep agent_pending and prompt_inflight until the agent's terminal reply.
    # Declining the questions unblocks it; pumping now could overlap two prompts.
    %{
      slot
      | fan_pending: Map.new(remaining),
        init_waiters: Enum.reject(slot.init_waiters, &(&1.client_id == client_id)),
        prompt_queue: :queue.filter(&(&1.client_id != client_id), slot.prompt_queue)
    }
  end

  defp drop_slot(state, name, reason) do
    case Map.pop(state.slots, name) do
      {nil, _} ->
        state

      {slot, slots} ->
        fail_slot(state, slot, reason)
        %{state | slots: slots}
    end
  end

  defp fail_slot(state, slot, reason) do
    error = {:error, reason}

    Enum.each(slot.agent_pending, fn {_id, pending} ->
      reply(state, pending.client_id, pending.client_req_id, error)
    end)

    Enum.each(slot.init_waiters, fn waiter ->
      reply(state, waiter.client_id, waiter.id, error)
    end)

    drain_queue(slot.prompt_queue, state, reason)
  end

  defp drain_queue(queue, state, reason) do
    case :queue.out(queue) do
      {:empty, _} ->
        :ok

      {{:value, item}, rest} ->
        reply(state, item.client_id, item.message["id"], {:error, reason})
        drain_queue(rest, state, reason)
    end
  end

  defp write_agent(slot, message) do
    case AgentLink.Registry.pid(slot.name) do
      pid when is_pid(pid) ->
        send(pid, {:send, Jason.encode!(message)})
        :ok

      _ ->
        :down
    end
  end

  defp publish(slot, session_id, update) do
    AgentLink.Plane.Sessions.broadcast(slot.name, session_id, update)
  end

  defp fanout(state, slot, session_id, message) do
    json = Jason.encode!(message)

    Enum.each(peers(state, slot.name, session_id), fn {_id, %{pid: pid}} ->
      send(pid, {:send, json})
    end)

    state
  end

  defp peers(state, name, nil) do
    Enum.filter(state.clients, fn {_id, %{runtime: runtime}} -> runtime == name end)
  end

  defp peers(state, name, session_id) do
    Enum.filter(state.clients, fn {_id, client} ->
      client.runtime == name and client.session_id == session_id
    end)
  end

  defp bind_session(state, client_id, session_id) when is_binary(session_id) do
    case state.clients[client_id] do
      nil ->
        state

      client ->
        %{state | clients: Map.put(state.clients, client_id, %{client | session_id: session_id})}
    end
  end

  defp bind_session(state, _client_id, _session_id), do: state

  defp release_session(state, client_id, session_id) do
    case state.clients[client_id] do
      %AgentLink.Client{session_id: ^session_id} = client ->
        %{state | clients: Map.put(state.clients, client_id, %{client | session_id: nil})}

      _ ->
        state
    end
  end

  defp open_session(state, slot, pending, session_id) do
    case state.clients[pending.client_id] do
      %AgentLink.Client{pid: pid} ->
        :ok =
          AgentLink.Plane.Sessions.open(slot.name, session_id, pending.client_id, pid, %{
            cwd: pending.cwd
          })

        state

      nil ->
        state
    end
  end

  defp client_pid(state, client_id) do
    %AgentLink.Client{pid: pid} = state.clients[client_id]
    pid
  end

  defp client_runtime(state, client_id) do
    case state.clients[client_id] do
      %{runtime: runtime} -> runtime
      _ -> nil
    end
  end

  defp push(state, client_id, message) do
    case state.clients[client_id] do
      %{pid: pid} -> send(pid, {:send, Jason.encode!(message)})
      _ -> :ok
    end

    state
  end

  defp reply(state, client_id, id, {:ok, result}) do
    push(state, client_id, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp reply(state, client_id, id, {:error, message}) when is_binary(message) do
    push(state, client_id, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32000, "message" => message}
    })
  end

  defp reply(state, client_id, id, {:error, error}) when is_map(error) do
    push(state, client_id, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
  end

  defp send_cache(state, client_id, id, {:ok, result}),
    do: reply(state, client_id, id, {:ok, result})

  defp send_cache(state, client_id, id, {:error, error}),
    do: reply(state, client_id, id, {:error, error})

  defp cache_of(%{"error" => error}) when is_map(error), do: {:error, error}
  defp cache_of(%{"result" => result}), do: {:ok, result}
  defp cache_of(_), do: {:error, "empty response"}

  defp response?(message) do
    not is_nil(message["id"]) and
      (Map.has_key?(message, "result") or Map.has_key?(message, "error")) and
      not is_binary(message["method"])
  end

  defp session_of(%{"params" => params}) when is_map(params) do
    case params["sessionId"] do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp session_of(_message), do: nil

  defp update_of(%{"params" => %{"update" => update}}) when is_map(update), do: update
  defp update_of(_message), do: nil

  # The relay fills a missing cwd on the agent machine. The directory needs a
  # binary before that write, so a missing or empty cwd uses this machine's
  # workspace.
  defp cwd_of(%{"params" => %{"cwd" => cwd}}) when is_binary(cwd) and cwd != "", do: cwd
  defp cwd_of(_message), do: AgentLink.Paths.workdir()

  defp list_args(nil), do: {:ok, []}

  defp list_args(params) when is_map(params) do
    with {:ok, opts} <- list_cwd(params, []),
         {:ok, opts} <- list_cursor(params, opts) do
      {:ok, opts}
    end
  end

  defp list_args(_params), do: {:error, "invalid params"}

  defp list_cwd(params, opts) do
    case Map.get(params, "cwd", :absent) do
      :absent -> {:ok, opts}
      nil -> {:ok, opts}
      cwd when is_binary(cwd) -> {:ok, Keyword.put(opts, :cwd, cwd)}
      _ -> {:error, "invalid cwd"}
    end
  end

  defp list_cursor(params, opts) do
    case Map.get(params, "cursor", :absent) do
      :absent -> {:ok, opts}
      nil -> {:ok, opts}
      cursor when is_binary(cursor) -> {:ok, Keyword.put(opts, :cursor, cursor)}
      _ -> {:error, "invalid cursor"}
    end
  end

  defp list_result(sessions, nil), do: %{"sessions" => sessions}

  defp list_result(sessions, next) when is_binary(next) do
    %{"sessions" => sessions, "nextCursor" => next}
  end

  defp fail(state, client_id, id, code, message) do
    reply(state, client_id, id, {:error, %{"code" => code, "message" => message}})
  end

  defp stop_reason(%{"result" => %{"stopReason" => reason}}) when is_binary(reason), do: reason
  defp stop_reason(%{"error" => _}), do: "error"
  defp stop_reason(_), do: "end_turn"

  defp prompt_text(%{"params" => %{"prompt" => parts}}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join()
  end

  defp prompt_text(_), do: ""

  defp new_slot(name), do: %AgentLink.AgentSlot{name: name}
end
