defmodule AgentLink.Plane.Sessions do
  @moduledoc """
  The session directory. The plane calls this module. It maps each client
  id to that client's subscription pids. `AgentLink.Plane.Session` holds the
  pids and does not keep that map.

  `open/5` starts the session when that runtime and session id are new, then
  subscribes the client. A second `open/5` for the same pair subscribes the
  client and leaves the stored history, including its `cwd`. `load/4`
  subscribes and returns the replay. `resume/4` subscribes and returns `:ok`.
  An unknown session is `{:error, :unknown}` from `load/4` and from `resume/4`.

  `leave/3` drops one client from one session. `disconnect/1` drops that
  client from every session, including a subscription that has already
  exited. `stop/1` and `unsubscribe/2` run only when that subscription is
  alive. The session process and its history stay, so a later `load/4`
  still returns the replay.

  `broadcast/3` appends one inner update on a known session. `update` is the
  object `AgentLink.Plane.History.append/2` stores. An unknown session returns
  `:ok`.

  `list/2` returns the `session/list` rows for one runtime, newest `updatedAt`
  first. A row with `updatedAt` `nil` sorts after a row that has one. Equal
  timestamps sort by `sessionId` ascending. `:cwd` keeps the rows with that
  working directory. `:cursor` is the opaque token from the previous
  `next_cursor`. If the cursor does not decode, `list/2` returns
  `{:error, :invalid_cursor}`. If the cursor was issued for another runtime,
  `list/2` returns the same error. Each page has at
  most 50 rows. `next_cursor` is `nil` on the last page.

  `:subscribe` on `start_link/1` defaults to `AgentLink.Plane.Subscription`.
  `AgentLink.Plane.Supervisor` starts this directory.

  The directory traps exits and is linked to each session. A session crash
  removes that session. The directory and the other sessions keep running.
  Their history stays in those session processes.
  """

  use GenServer
  require Logger

  @page_size 50

  defstruct [:subscribe, sessions: %{}, clients: %{}]

  @doc """
  Start the directory.

  `:subscribe` is the `AgentLink.Plane.Subscribe` module started for each
  client. It defaults to `AgentLink.Plane.Subscription`.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, initial(opts), name: __MODULE__)
  end

  @impl true
  def init(%__MODULE__{} = state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @doc """
  Start the session when it is new, and subscribe this client.

  `attrs` requires `:cwd`, a binary. `:history` is an optional keyword, default
  `[]`, passed through to `AgentLink.Plane.Session.start_link/1`. When the
  session already exists, the stored history stays.
  """
  @spec open(String.t(), String.t(), String.t(), pid, map) :: :ok
  def open(runtime, session_id, client_id, client_pid, attrs)
      when is_binary(runtime) and is_binary(session_id) and is_binary(client_id) and
             is_pid(client_pid) and is_map(attrs) do
    # Raise in the caller. A bad :history inside the directory would take it down.
    AgentLink.Plane.History.new(history_args(session_id, attrs))
    GenServer.call(__MODULE__, {:open, runtime, session_id, client_id, client_pid, attrs})
  end

  @doc """
  Subscribe this client and return the capped replay.

  The replay is a list of `session/update` messages, oldest first. An unknown
  session is `{:error, :unknown}`.
  """
  @spec load(String.t(), String.t(), String.t(), pid) :: {:ok, [map]} | {:error, :unknown}
  def load(runtime, session_id, client_id, client_pid)
      when is_binary(runtime) and is_binary(session_id) and is_binary(client_id) and
             is_pid(client_pid) do
    GenServer.call(__MODULE__, {:load, runtime, session_id, client_id, client_pid})
  end

  @doc """
  Subscribe this client without a replay.

  Returns `:ok`, or `{:error, :unknown}` when the session is not in the
  directory.
  """
  @spec resume(String.t(), String.t(), String.t(), pid) :: :ok | {:error, :unknown}
  def resume(runtime, session_id, client_id, client_pid)
      when is_binary(runtime) and is_binary(session_id) and is_binary(client_id) and
             is_pid(client_pid) do
    GenServer.call(__MODULE__, {:resume, runtime, session_id, client_id, client_pid})
  end

  @doc """
  Drop this client's subscription for one session.

  Returns `:ok` when the client has no subscription for that session. The
  session and its history stay. If the subscription has already exited, the
  directory entry is still removed, and `stop/1` and `unsubscribe/2` are not
  called.
  """
  @spec leave(String.t(), String.t(), String.t()) :: :ok
  def leave(runtime, session_id, client_id)
      when is_binary(runtime) and is_binary(session_id) and is_binary(client_id) do
    GenServer.call(__MODULE__, {:leave, runtime, session_id, client_id})
  end

  @doc """
  Drop every subscription for this client.

  Returns `:ok` when the client has none. Sessions and their history stay.
  If a subscription has already exited, that directory entry is still
  removed, and `stop/1` and `unsubscribe/2` are not called.
  """
  @spec disconnect(String.t()) :: :ok
  def disconnect(client_id) when is_binary(client_id) do
    GenServer.call(__MODULE__, {:disconnect, client_id})
  end

  @doc """
  Append one inner `session/update` object on a known session.

  An unknown session returns `:ok` and stores nothing.
  """
  @spec broadcast(String.t(), String.t(), map) :: :ok
  def broadcast(runtime, session_id, update)
      when is_binary(runtime) and is_binary(session_id) and is_map(update) do
    GenServer.call(__MODULE__, {:broadcast, runtime, session_id, update})
  end

  @doc """
  The `session/list` rows for one runtime.

  `:cwd` keeps rows with that working directory. Omit it to return every cwd.
  `:cursor` is the opaque token from a previous `next_cursor`. Omit it for the
  first page. The result is `%{sessions: rows, next_cursor: token | nil}`, or
  `{:error, :invalid_cursor}` when the cursor is not one this directory issued
  for `runtime`. Each page has at most 50 rows.
  """
  @spec list(String.t(), keyword) ::
          %{sessions: [map], next_cursor: String.t() | nil} | {:error, :invalid_cursor}
  def list(runtime, opts \\ []) when is_binary(runtime) and is_list(opts) do
    list_cwd!(opts)
    list_cursor!(opts)
    GenServer.call(__MODULE__, {:list, runtime, opts})
  end

  @impl true
  def handle_call({:open, runtime, session_id, client_id, client_pid, attrs}, _from, state) do
    state = ensure_session(state, runtime, session_id, attrs)
    {:reply, :ok, ensure_client(state, runtime, session_id, client_id, client_pid)}
  end

  def handle_call({:load, runtime, session_id, client_id, client_pid}, _from, state) do
    case fetch_session(state, runtime, session_id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      pid ->
        key = {runtime, session_id}

        {state, replay} =
          case current(state, client_id, key) do
            nil ->
              subscribe(state, pid, runtime, session_id, client_id, client_pid)

            _subscription ->
              {state, AgentLink.Plane.Session.replay(pid)}
          end

        {:reply, {:ok, replay}, state}
    end
  end

  def handle_call({:resume, runtime, session_id, client_id, client_pid}, _from, state) do
    case fetch_session(state, runtime, session_id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      _pid ->
        {:reply, :ok, ensure_client(state, runtime, session_id, client_id, client_pid)}
    end
  end

  def handle_call({:leave, runtime, session_id, client_id}, _from, state) do
    {:reply, :ok, drop(state, client_id, [{runtime, session_id}])}
  end

  def handle_call({:disconnect, client_id}, _from, state) do
    keys = Map.keys(Map.get(state.clients, client_id, %{}))
    {:reply, :ok, drop(state, client_id, keys)}
  end

  def handle_call({:broadcast, runtime, session_id, update}, _from, state) do
    case fetch_session(state, runtime, session_id) do
      nil -> :ok
      pid -> AgentLink.Plane.Session.broadcast(pid, update)
    end

    {:reply, :ok, state}
  end

  def handle_call({:list, runtime, opts}, _from, state) do
    rows =
      state
      |> rows(runtime)
      |> Enum.filter(&cwd_match?(&1, Keyword.get(opts, :cwd)))
      |> Enum.sort(&before?/2)

    {:reply, page(rows, runtime, Keyword.get(opts, :cursor)), state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %__MODULE__{} = state) do
    if reason != :normal do
      Logger.warning("session #{inspect(pid)} stopped #{inspect(reason)}")
    end

    {:noreply, forget_session(state, pid)}
  end

  defp forget_session(state, pid) do
    case Enum.find(state.sessions, fn {_key, session} -> session == pid end) do
      nil ->
        state

      {key, _session} ->
        %{
          state
          | sessions: Map.delete(state.sessions, key),
            clients: drop_client_key(state.clients, key)
        }
    end
  end

  defp drop_client_key(clients, key) do
    Enum.reduce(clients, %{}, fn {client_id, subs}, acc ->
      subs = Map.delete(subs, key)

      if subs == %{} do
        acc
      else
        Map.put(acc, client_id, subs)
      end
    end)
  end

  defp initial(opts) do
    %__MODULE__{subscribe: AgentLink.Plane.Session.subscribe_module!(opts)}
  end

  defp ensure_session(state, runtime, session_id, attrs) do
    case fetch_session(state, runtime, session_id) do
      nil ->
        {:ok, pid} =
          AgentLink.Plane.Session.start_link(
            runtime: runtime,
            session_id: session_id,
            cwd: cwd!(attrs),
            history: history_opts(attrs),
            subscribe: state.subscribe
          )

        %{state | sessions: Map.put(state.sessions, {runtime, session_id}, pid)}

      _pid ->
        state
    end
  end

  defp ensure_client(state, runtime, session_id, client_id, client_pid) do
    key = {runtime, session_id}

    case current(state, client_id, key) do
      pid when is_pid(pid) ->
        state

      nil ->
        pid = fetch_session(state, runtime, session_id)
        {state, _replay} = subscribe(state, pid, runtime, session_id, client_id, client_pid)
        state
    end
  end

  defp subscribe(state, session_pid, runtime, session_id, client_id, client_pid) do
    key = {runtime, session_id}

    {:ok, subscription, replay} =
      AgentLink.Plane.Session.subscribe(session_pid,
        client_pid: client_pid,
        client_id: client_id
      )

    {remember(state, client_id, key, subscription), replay}
  end

  defp drop(state, client_id, keys) do
    Enum.reduce(keys, state, fn key, state ->
      case get_in(state.clients, [client_id, key]) do
        subscription when is_pid(subscription) ->
          if Process.alive?(subscription) do
            state.subscribe.stop(subscription)

            case fetch_session(state, runtime_of(key), session_of(key)) do
              nil -> :ok
              pid -> AgentLink.Plane.Session.unsubscribe(pid, subscription)
            end
          end

          forget(state, client_id, key)

        _absent ->
          state
      end
    end)
  end

  defp runtime_of({runtime, _session_id}), do: runtime
  defp session_of({_runtime, session_id}), do: session_id

  defp fetch_session(state, runtime, session_id) do
    case Map.get(state.sessions, {runtime, session_id}) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  defp rows(state, runtime) do
    state.sessions
    |> Enum.flat_map(fn
      {{^runtime, _session_id}, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: [AgentLink.Plane.Session.info(pid)], else: []

      _other ->
        []
    end)
  end

  defp current(state, client_id, key) do
    pid = get_in(state.clients, [client_id, key])
    if is_pid(pid) and Process.alive?(pid), do: pid
  end

  defp remember(state, client_id, key, subscription) do
    clients =
      Map.update(
        state.clients,
        client_id,
        %{key => subscription},
        &Map.put(&1, key, subscription)
      )

    %{state | clients: clients}
  end

  defp forget(state, client_id, key) do
    case Map.get(state.clients, client_id) do
      nil ->
        state

      subs ->
        subs = Map.delete(subs, key)

        clients =
          if subs == %{} do
            Map.delete(state.clients, client_id)
          else
            Map.put(state.clients, client_id, subs)
          end

        %{state | clients: clients}
    end
  end

  defp history_args(session_id, attrs) do
    Keyword.merge(history_opts(attrs), session_id: session_id, cwd: cwd!(attrs))
  end

  defp history_opts(%{history: history}), do: AgentLink.Plane.Session.history!(history)
  defp history_opts(%{}), do: []

  defp cwd!(%{cwd: cwd}) when is_binary(cwd), do: cwd

  defp cwd!(%{cwd: cwd}) do
    raise ArgumentError, ":cwd must be a binary, got: #{inspect(cwd)}"
  end

  defp cwd!(%{}) do
    raise KeyError, key: :cwd
  end

  defp list_cwd!(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> :ok
      cwd when is_binary(cwd) -> :ok
      cwd -> raise ArgumentError, ":cwd must be a binary, got: #{inspect(cwd)}"
    end
  end

  defp list_cursor!(opts) do
    case Keyword.get(opts, :cursor) do
      nil -> :ok
      cursor when is_binary(cursor) -> :ok
      cursor -> raise ArgumentError, ":cursor must be a binary, got: #{inspect(cursor)}"
    end
  end

  defp cwd_match?(_row, nil), do: true
  defp cwd_match?(row, cwd), do: row["cwd"] == cwd

  defp before?(left, right) do
    cond do
      left["updatedAt"] == right["updatedAt"] -> left["sessionId"] <= right["sessionId"]
      is_nil(left["updatedAt"]) -> false
      is_nil(right["updatedAt"]) -> true
      left["updatedAt"] > right["updatedAt"] -> true
      true -> false
    end
  end

  defp page(rows, runtime, nil), do: pack(rows, runtime)

  defp page(rows, runtime, cursor) do
    case decode_cursor(runtime, cursor) do
      {:ok, at, id} ->
        rows
        |> Enum.drop_while(fn row -> not after_cursor?(row, at, id) end)
        |> pack(runtime)

      :error ->
        {:error, :invalid_cursor}
    end
  end

  defp pack(rows, runtime) do
    {page, rest} = Enum.split(rows, @page_size)

    next =
      case rest do
        [] -> nil
        _more -> encode_cursor(runtime, List.last(page))
      end

    %{sessions: page, next_cursor: next}
  end

  defp after_cursor?(row, at, id) do
    cond do
      row["updatedAt"] == at -> row["sessionId"] > id
      is_nil(at) -> is_nil(row["updatedAt"]) and row["sessionId"] > id
      is_nil(row["updatedAt"]) -> true
      row["updatedAt"] < at -> true
      true -> false
    end
  end

  defp encode_cursor(runtime, row) do
    %{
      "v" => 1,
      "runtime" => runtime,
      "updatedAt" => row["updatedAt"],
      "sessionId" => row["sessionId"]
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(runtime, cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(raw),
         %{"v" => 1, "runtime" => ^runtime, "sessionId" => id} <- map,
         true <- is_binary(id),
         true <- Map.has_key?(map, "updatedAt"),
         at when is_binary(at) or is_nil(at) <- map["updatedAt"] do
      {:ok, at, id}
    else
      _ -> :error
    end
  end
end
