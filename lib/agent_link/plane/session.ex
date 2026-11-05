defmodule AgentLink.Plane.Session do
  @moduledoc """
  One shared session. The process holds an `AgentLink.Plane.History` and the
  subscription pids. It does not store client ids, and it does not read client
  capabilities.

  `subscribe/2` starts one `AgentLink.Plane.Subscribe` process. The return is
  `{:ok, subscription_pid, replay}`. `replay` is the capped history as full
  `session/update` messages, oldest first. `subscribe/2` does not pass that
  replay to `notify/2`. `replay/1` returns the same list and does not start a
  subscription.

  `broadcast/2` appends one inner `session/update` object to the history, then
  calls `notify/2` on each subscription with that object wrapped as a
  `session/update` message. `info/1` is the `session/list` row from
  `AgentLink.Plane.History.info/1`.

  `:history` is a keyword passed to `AgentLink.Plane.History.new/1`.
  `:session_id` and `:cwd` from `start_link/1` win over the same keys in
  `:history`. `:subscribe` is the module, default
  `AgentLink.Plane.Subscription`.

  `AgentLink.Plane.Sessions` starts this process from `open/5`.
  """

  use GenServer

  defstruct [:runtime, :session_id, :subscribe, :history, subscriptions: []]

  @doc """
  Start one session process.

  `:runtime`, `:session_id`, and `:cwd` are required binaries. `:history`
  defaults to `[]` and is passed to `AgentLink.Plane.History.new/1`.
  `:subscribe` defaults to `AgentLink.Plane.Subscription`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, initial(opts))
  end

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @doc """
  Start a subscription and return the capped replay.

  `:client_pid` is a pid. `:client_id` is a binary. Both are required. The
  replay is a list of `session/update` messages, oldest first. An empty
  history returns `[]`.
  """
  @spec subscribe(pid, keyword) :: {:ok, pid, [map]}
  def subscribe(pid, opts) when is_pid(pid) and is_list(opts) do
    pid!(opts, :client_pid)
    binary!(opts, :client_id)
    GenServer.call(pid, {:subscribe, opts})
  end

  @doc """
  Drop one subscription pid.

  The subscription process keeps running. Returns `:ok` when that pid is
  already absent.
  """
  @spec unsubscribe(pid, pid) :: :ok
  def unsubscribe(pid, subscription) when is_pid(pid) and is_pid(subscription) do
    GenServer.call(pid, {:unsubscribe, subscription})
  end

  @doc """
  Append one inner `session/update` object and pass it to every subscription.

  `update` is the object `AgentLink.Plane.History.append/2` stores. Each
  subscription receives that object wrapped as a `session/update` message.
  """
  @spec broadcast(pid, map) :: :ok
  def broadcast(pid, update) when is_pid(pid) and is_map(update) do
    GenServer.call(pid, {:broadcast, update})
  end

  @doc "The `session/list` row for this session."
  @spec info(pid) :: map
  def info(pid) when is_pid(pid), do: GenServer.call(pid, :info)

  @doc """
  The capped replay as full `session/update` messages, oldest first.

  `replay/1` does not start a subscription and does not call `notify/2`.
  """
  @spec replay(pid) :: [map]
  def replay(pid) when is_pid(pid), do: GenServer.call(pid, :replay)

  @impl true
  def handle_call({:subscribe, opts}, _from, %__MODULE__{} = state) do
    {:ok, subscription} =
      state.subscribe.start_link(
        client_pid: opts[:client_pid],
        client_id: opts[:client_id],
        session_id: state.session_id,
        owner: self()
      )

    Process.monitor(subscription)

    {:reply, {:ok, subscription, messages(state)},
     %{state | subscriptions: state.subscriptions ++ [subscription]}}
  end

  def handle_call({:unsubscribe, subscription}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | subscriptions: List.delete(state.subscriptions, subscription)}}
  end

  def handle_call({:broadcast, update}, _from, %__MODULE__{} = state) do
    state = %{state | history: AgentLink.Plane.History.append(state.history, update)}
    {:reply, :ok, deliver(state, wrap(state.session_id, update))}
  end

  def handle_call(:info, _from, %__MODULE__{} = state) do
    {:reply, AgentLink.Plane.History.info(state.history), state}
  end

  def handle_call(:replay, _from, %__MODULE__{} = state) do
    {:reply, messages(state), state}
  end

  # The subscription sends this before it exits. DOWN removes the pid. The
  # client id in the message is not stored.
  @impl true
  def handle_info({:subscription_down, _client_id, _session_id}, %__MODULE__{} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    {:noreply, %{state | subscriptions: List.delete(state.subscriptions, pid)}}
  end

  defp initial(opts) do
    session_id = binary!(opts, :session_id)
    cwd = binary!(opts, :cwd)

    history =
      opts
      |> Keyword.get(:history, [])
      |> history!()
      |> Keyword.merge(session_id: session_id, cwd: cwd)
      |> AgentLink.Plane.History.new()

    %__MODULE__{
      runtime: binary!(opts, :runtime),
      session_id: session_id,
      subscribe: subscribe_module!(opts),
      history: history
    }
  end

  # AgentLink.Plane.Sessions calls these. The directory does not repeat the check.
  @doc false
  def history!(history) do
    if Keyword.keyword?(history) do
      history
    else
      raise ArgumentError, ":history must be a keyword, got: #{inspect(history)}"
    end
  end

  @doc false
  def subscribe_module!(opts) when is_list(opts) do
    module = Keyword.get(opts, :subscribe, AgentLink.Plane.Subscription)

    if is_atom(module) do
      module
    else
      raise ArgumentError, ":subscribe must be a module, got: #{inspect(module)}"
    end
  end

  defp pid!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_pid(value) do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a pid, got: #{inspect(value)}"
    end
  end

  defp binary!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_binary(value) do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a binary, got: #{inspect(value)}"
    end
  end

  defp messages(%__MODULE__{} = state) do
    Enum.map(AgentLink.Plane.History.replay(state.history), &wrap(state.session_id, &1))
  end

  defp wrap(session_id, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => session_id, "update" => update}
    }
  end

  # A client can die before this process handles DOWN. notify/2 on that pid
  # must not drop the update for the subscriptions that are still up.
  defp deliver(%__MODULE__{} = state, message) do
    subscriptions =
      Enum.flat_map(state.subscriptions, fn pid ->
        try do
          state.subscribe.notify(pid, message)
          [pid]
        catch
          :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal] ->
            []
        end
      end)

    %{state | subscriptions: subscriptions}
  end
end
