defmodule Acp.Client do
  @moduledoc false
  defstruct [:pid, runtime: nil, session_id: nil]
end

defmodule Acp.Slot do
  @moduledoc false
  defstruct [
    :name,
    agent_pending: %{},
    fan_pending: %{},
    groups: %{},
    prompt_queue: :queue.new(),
    prompt_inflight: false,
    next_agent_id: 1_000_000,
    next_fan_id: 1,
    init_sent: false,
    init_cache: nil,
    init_waiters: []
  ]
end

defmodule Acp.Plane do
  @moduledoc """
  WebSocket proxy for ACP stdio. `initialize` is cached per agent. Every other
  method is forwarded. Clients on the same `{agent, sessionId}` share live
  updates. One agent process runs one prompt at a time.
  """

  use GenServer

  defstruct clients: %{}, monitors: %{}, slots: %{}

  @doc "Start the named broker. One plane owns every app and every agent socket."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @doc "An app socket connected. Remember it and hand back its id."
  def register(pid) when is_pid(pid), do: GenServer.call(__MODULE__, {:register, pid})

  @impl true
  def handle_call({:register, pid}, _from, %__MODULE__{} = state) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    ref = Process.monitor(pid)

    state = %{
      state
      | clients: Map.put(state.clients, id, %Acp.Client{pid: pid}),
        monitors: Map.put(state.monitors, ref, id)
    }

    {:reply, id, state}
  end

  @doc "Text from an app. Route it as ACP from that client."
  def client_frame(client_id, text), do: GenServer.cast(__MODULE__, {:frame, client_id, text})

  @doc "Text from a sidecar. Route it as ACP from that agent."
  def agent_frame(name, text) when is_binary(name) and is_binary(text),
    do: GenServer.cast(__MODULE__, {:agent_frame, name, text})

  @doc "The same agent dialed again. Drop the cached slot so the next app initializes it fresh."
  def runtime_reset(name) when is_binary(name), do: GenServer.cast(__MODULE__, {:runtime_reset, name})

  @doc "The agent socket closed. Fail whatever was still waiting on it."
  def runtime_down(name) when is_binary(name), do: GenServer.cast(__MODULE__, {:runtime_down, name})

  @impl true
  def handle_cast({:frame, client_id, text}, %__MODULE__{} = state) do
    state =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(state, fn line, acc ->
        case Jason.decode(line) do
          {:ok, message} when is_map(message) -> on_client(acc, client_id, message)
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

  def handle_cast({:runtime_reset, name}, %__MODULE__{} = state), do: {:noreply, drop_slot(state, name, "runtime reconnected")}
  def handle_cast({:runtime_down, name}, %__MODULE__{} = state), do: {:noreply, drop_slot(state, name, "runtime disconnected")}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {client_id, monitors} ->
        {:noreply, %{state | clients: Map.delete(state.clients, client_id), monitors: monitors}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp on_client(state, client_id, message) do
    cond do
      response?(message) ->
        with_runtime(state, client_id, message, &on_client_response/4)

      not is_binary(message["method"]) ->
        state

      message["method"] in ["runtime/list", "runtime/select"] ->
        on_runtime(state, client_id, message)

      message["id"] == nil ->
        with_runtime(state, client_id, message, fn state, slot, _client_id, message ->
          write_agent(slot, message)
          {state, slot}
        end)

      message["method"] == "initialize" ->
        with_runtime(state, client_id, message, &on_initialize/4)

      message["method"] == "session/prompt" ->
        with_runtime(state, client_id, message, fn state, slot, client_id, message ->
          slot = %{slot | prompt_queue: :queue.in(%{client_id: client_id, message: message}, slot.prompt_queue)}
          pump(state, slot)
        end)

      true ->
        kind =
          case message["method"] do
            "session/new" -> :session_new
            "session/load" -> :session_load
            _ -> :forward
          end

        with_runtime(state, client_id, message, fn state, slot, client_id, message ->
          forward(state, slot, client_id, message, kind)
        end)
    end
  end

  defp on_runtime(state, client_id, %{"method" => "runtime/list", "id" => id}) do
    reply(state, client_id, id, {:ok, %{"runtimes" => Acp.Registry.list()}})
  end

  defp on_runtime(state, client_id, %{"method" => "runtime/select", "id" => id} = message) do
    name = get_in(message, ["params", "name"])

    cond do
      not is_binary(name) ->
        reply(state, client_id, id, {:error, "runtime name is required"})

      is_nil(Acp.Registry.pid(name)) ->
        reply(state, client_id, id, {:error, "runtime is not connected"})

      true ->
        clients = Map.update!(state.clients, client_id, &%{&1 | runtime: name})
        row = Enum.find(Acp.Registry.list(), &(&1["name"] == name))
        reply(%{state | clients: clients}, client_id, id, {:ok, row})
    end
  end

  defp on_runtime(state, client_id, message) do
    if message["id"] do
      reply(state, client_id, message["id"], {:error, "runtime request needs an id"})
    else
      state
    end
  end

  defp with_runtime(state, client_id, message, fun) do
    case ensure_runtime(state, client_id) do
      {:ok, state, name} ->
        slot = Map.get(state.slots, name) || new_slot(name)
        {state, slot} = fun.(state, slot, client_id, message)
        %{state | slots: Map.put(state.slots, slot.name, slot)}

      {:error, state, reason} ->
        if message["id"], do: reply(state, client_id, message["id"], {:error, reason}), else: state
    end
  end

  defp ensure_runtime(state, client_id) do
    case state.clients[client_id] do
      %{runtime: name} when is_binary(name) ->
        {:ok, state, name}

      _ ->
        case Acp.Registry.list() do
          [%{"name" => name}] ->
            clients = Map.update!(state.clients, client_id, &%{&1 | runtime: name})
            {:ok, %{state | clients: clients}, name}

          [] ->
            {:error, state, "no runtime connected"}

          _ ->
            {:error, state, "select a runtime"}
        end
    end
  end

  defp on_initialize(state, slot, client_id, message) do
    cond do
      slot.init_cache ->
        {send_cache(state, client_id, message["id"], slot.init_cache), slot}

      slot.init_sent ->
        {state, %{slot | init_waiters: slot.init_waiters ++ [%{client_id: client_id, id: message["id"]}]}}

      true ->
        slot = %{slot | init_waiters: slot.init_waiters ++ [%{client_id: client_id, id: message["id"]}]}
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

  defp forward(state, slot, client_id, message, kind) do
    agent_id = slot.next_agent_id

    case write_agent(slot, Map.put(message, "id", agent_id)) do
      :ok ->
        pending = %{
          client_id: client_id,
          client_req_id: message["id"],
          kind: kind,
          session_id: session_of(message)
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
          fan_out(state, slot, message)

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

  defp deliver(state, slot, %{kind: kind} = pending, message) when kind in [:session_new, :session_load] do
    cache = cache_of(message)
    state = reply(state, pending.client_id, pending.client_req_id, cache)

    state =
      case cache do
        {:ok, result} ->
          session_id = if kind == :session_new, do: result["sessionId"], else: pending.session_id
          bind_session(state, pending.client_id, session_id)

        _ ->
          state
      end

    {state, slot}
  end

  defp deliver(state, slot, pending, message) do
    state = reply(state, pending.client_id, pending.client_req_id, cache_of(message))

    if pending.kind == :prompt do
      session_id = pending.session_id

      state =
        if is_binary(session_id) do
          broadcast(state, slot, session_id, %{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => session_id,
              "update" => %{
                "sessionUpdate" => "session_info_update",
                "_meta" => %{"stopReason" => stop_reason(message)}
              }
            }
          })
        else
          state
        end

      pump(state, %{slot | prompt_inflight: false})
    else
      {state, slot}
    end
  end

  defp route_notice(state, slot, message) do
    session_id = session_of(message)

    case load_in_flight(slot, session_id) do
      %{client_id: client_id} ->
        push(state, client_id, message)

      nil when is_binary(session_id) ->
        broadcast(state, slot, session_id, message)

      nil ->
        broadcast(state, slot, nil, message)
    end
  end

  defp load_in_flight(slot, session_id) when is_binary(session_id) do
    Enum.find_value(slot.agent_pending, fn {_id, pending} ->
      if pending.kind == :session_load and pending.session_id == session_id, do: pending
    end)
  end

  defp load_in_flight(_slot, _session_id), do: nil

  defp fan_out(state, slot, message) do
    peers = peers(state, slot.name, session_of(message))

    if peers == [] do
      write_agent(slot, %{
        "jsonrpc" => "2.0",
        "id" => message["id"],
        "error" => %{"code" => -32000, "message" => "no app is attached to this session"}
      })

      {state, slot}
    else
      group = make_ref()
      slot = %{slot | groups: Map.put(slot.groups, group, false)}

      Enum.reduce(peers, {state, slot}, fn {client_id, _client}, {state, slot} ->
        fan_id = slot.next_fan_id
        state = push(state, client_id, Map.put(message, "id", fan_id))

        {state,
         %{
           slot
           | next_fan_id: fan_id + 1,
             fan_pending:
               Map.put(slot.fan_pending, fan_id, %{agent_id: message["id"], client_id: client_id, group: group})
         }}
      end)
    end
  end

  defp on_client_response(state, slot, client_id, message) do
    case Map.pop(slot.fan_pending, message["id"]) do
      {nil, _} ->
        {state, slot}

      {fan, fan_pending} when fan.client_id != client_id ->
        {state, %{slot | fan_pending: fan_pending}}

      {fan, fan_pending} ->
        slot = %{slot | fan_pending: fan_pending}

        if Map.get(slot.groups, fan.group) do
          {push(state, client_id, %{
             "jsonrpc" => "2.0",
             "id" => message["id"],
             "error" => %{"code" => -32600, "message" => "already answered"}
           }), slot}
        else
          payload =
            if message["error"] do
              %{"jsonrpc" => "2.0", "id" => fan.agent_id, "error" => message["error"]}
            else
              %{"jsonrpc" => "2.0", "id" => fan.agent_id, "result" => message["result"]}
            end

          write_agent(slot, payload)
          {state, %{slot | groups: Map.put(slot.groups, fan.group, true)}}
        end
    end
  end

  defp pump(state, %Acp.Slot{prompt_inflight: true} = slot), do: {state, slot}

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

    state =
      if is_binary(session_id) and text != "" do
        broadcast(state, slot, session_id, %{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{
            "sessionId" => session_id,
            "update" => %{
              "sessionUpdate" => "user_message_chunk",
              "content" => %{"type" => "text", "text" => text}
            }
          }
        })
      else
        state
      end

    agent_id = slot.next_agent_id
    {state, slot} = forward(state, slot, item.client_id, item.message, :prompt)

    if Map.has_key?(slot.agent_pending, agent_id) do
      {state, %{slot | prompt_inflight: true}}
    else
      pump(state, slot)
    end
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
    case Acp.Registry.pid(slot.name) do
      pid when is_pid(pid) ->
        send(pid, {:send, Jason.encode!(message)})
        :ok

      _ ->
        :down
    end
  end

  defp broadcast(state, slot, session_id, message) do
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
      nil -> state
      client -> %{state | clients: Map.put(state.clients, client_id, %{client | session_id: session_id})}
    end
  end

  defp bind_session(state, _client_id, _session_id), do: state

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

  defp send_cache(state, client_id, id, {:ok, result}), do: reply(state, client_id, id, {:ok, result})
  defp send_cache(state, client_id, id, {:error, error}), do: reply(state, client_id, id, {:error, error})

  defp cache_of(%{"error" => error}) when is_map(error), do: {:error, error}
  defp cache_of(%{"result" => result}), do: {:ok, result}
  defp cache_of(_), do: {:error, "empty response"}

  defp response?(message) do
    not is_nil(message["id"]) and (Map.has_key?(message, "result") or Map.has_key?(message, "error")) and
      not is_binary(message["method"])
  end

  defp session_of(message) do
    case get_in(message, ["params", "sessionId"]) do
      id when is_binary(id) -> id
      _ -> nil
    end
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

  defp new_slot(name), do: %Acp.Slot{name: name}
end
