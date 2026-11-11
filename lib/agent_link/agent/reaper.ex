defmodule AgentLink.Agent.Reaper do
  @moduledoc """
  It holds the OS processes `close/1` could not stop.

  See [Reaper](../../../docs/agent.md#reaper).
  """

  use GenServer

  require Logger

  @version 1
  @type vm :: {integer(), String.t()}

  defstruct [:vm, records: []]

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 2_000
    }
  end

  @doc """
  Start the reaper.

  See [Reaper](../../../docs/agent.md#reaper).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, server_opts(opts))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    vm = vm_opt(opts)
    reader = starttime_opt(opts)
    dir = directory()
    File.mkdir_p!(dir)

    records =
      trans(vm, fn ->
        sweep_stale(dir, vm, reader)
        records = vm |> record_path() |> load() |> verify()
        after_load()
        save(vm, records)
      end)

    {:ok, %__MODULE__{vm: vm, records: records}}
  end

  @doc """
  Remember processes `close/1` could not stop.

  See [Reaper](../../../docs/agent.md#reaper).
  """
  @spec retain([{integer(), String.t()}]) :: :ok | {:error, :noproc}
  def retain(identities) when is_list(identities) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:retain, identities})
      _ -> absent_retain(identities)
    end
  end

  @doc """
  Stop processes this reaper still holds.

  See [Reaper](../../../docs/agent.md#reaper).
  """
  @spec reap() :: :ok | {:error, :timeout | :no_kill | :kill_failed | :noproc}
  def reap do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :reap, 10_000)
      _ -> {:error, :noproc}
    end
  end

  @impl true
  def handle_call({:retain, identities}, _from, %__MODULE__{} = state) do
    records =
      trans(state.vm, fn ->
        state.vm
        |> record_path()
        |> load()
        |> merge(state.records)
        |> merge(identities)
        |> verify()
        |> then(&save(state.vm, &1))
      end)

    {:reply, :ok, %{state | records: records}}
  end

  def handle_call(:reap, _from, %__MODULE__{} = state) do
    case trans(state.vm, fn -> reap_locked(state) end) do
      {:ok, records} ->
        {:reply, :ok, %{state | records: records}}

      {{:error, reason}, records} ->
        {:reply, {:error, reason}, %{state | records: records}}
    end
  end

  @impl true
  def terminate(reason, %__MODULE__{vm: vm}) do
    if clean?(reason), do: trans(vm, fn -> File.rm(record_path(vm)) end)
    :ok
  end

  @doc false
  def vm_owner do
    pid = System.pid() |> String.to_integer()

    case AgentLink.Agent.Process.starttime(pid) do
      start when is_binary(start) -> {pid, start}
      _ -> {pid, "0"}
    end
  end

  @doc false
  def record_path, do: record_path(vm_owner())

  @doc false
  def record_path({pid, start}) when is_integer(pid) and is_binary(start) do
    Path.join(directory(), "agent-reaper-#{pid}-#{start}.bin")
  end

  @doc false
  def install_pairs(pairs) when is_list(pairs) do
    vm = vm_owner()
    trans(vm, fn -> save(vm, pairs) end)
  end

  @doc false
  def read_pairs do
    case File.read(record_path()) do
      {:ok, binary} ->
        case decode(binary) do
          {:ok, records} -> records
          :corrupt -> :corrupt
        end

      _ ->
        []
    end
  end

  defp server_opts(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      name when is_nil(name) or name == false -> []
      name -> [name: name]
    end
  end

  defp vm_opt(opts) do
    case Keyword.get(opts, :vm, vm_owner()) do
      {pid, start} when is_integer(pid) and pid > 0 and is_binary(start) ->
        {pid, start}

      other ->
        raise ArgumentError, "reaper vm must be {pid, starttime}, got: #{inspect(other)}"
    end
  end

  defp absent_retain(identities) do
    if pair?(identities) do
      vm = vm_owner()

      trans(vm, fn ->
        records = vm |> record_path() |> load() |> merge(identities) |> verify()
        save(vm, records)
      end)
    end

    {:error, :noproc}
  end

  defp trans(vm, fun) when is_function(fun, 0) do
    before_lock()
    :global.trans({{:agentlink_reaper, vm}, self()}, fun, [node()])
  end

  defp before_lock do
    case Application.get_env(:agent_link, :reaper_before_lock) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp after_load do
    case Application.get_env(:agent_link, :reaper_after_load) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp starttime_opt(opts) do
    case Keyword.get(opts, :starttime, &default_starttime/1) do
      reader when is_function(reader, 1) ->
        reader

      other ->
        raise ArgumentError, "reaper starttime reader must be a function, got: #{inspect(other)}"
    end
  end

  defp default_starttime(pid) when is_integer(pid) and pid > 0 do
    cond do
      not File.dir?("/proc") ->
        :unknown

      not File.dir?("/proc/#{pid}") ->
        :gone

      true ->
        case AgentLink.Agent.Process.starttime(pid) do
          start when is_binary(start) and start != "0" -> {:ok, start}
          _ -> :unknown
        end
    end
  end

  defp reap_locked(state) do
    records =
      state.vm
      |> record_path()
      |> load()
      |> merge(state.records)
      |> verify()

    case AgentLink.Agent.Process.force(records) do
      :ok ->
        save(state.vm, [])
        {:ok, []}

      {:error, reason} ->
        records = verify(records)
        save(state.vm, records)
        {{:error, reason}, records}
    end
  end

  defp pair?(identities) do
    Enum.any?(identities, fn
      {pid, start} when is_integer(pid) and is_binary(start) -> true
      _ -> false
    end)
  end

  defp clean?(:normal), do: true
  defp clean?(:shutdown), do: true
  defp clean?({:shutdown, _}), do: true
  defp clean?(_reason), do: false

  defp directory do
    Application.get_env(:agent_link, :reaper_dir) ||
      System.get_env("RELEASE_TMP") ||
      Path.join(AgentLink.Paths.root(), "run")
  end

  defp sweep_stale(dir, vm, reader) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          case owner_from_name(name) do
            ^vm -> drop_own_extra(dir, name)
            {_pid, _start} = other -> maybe_drop(dir, name, other, reader)
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp drop_own_extra(dir, name) do
    if extra?(name), do: File.rm(Path.join(dir, name))
  end

  defp extra?(name) do
    String.contains?(name, ".bin.bad-") or String.ends_with?(name, ".tmp")
  end

  defp maybe_drop(_dir, _name, {_pid, "0"}, _reader), do: :ok

  defp maybe_drop(dir, name, {pid, start}, reader) do
    case reader.(pid) do
      :gone ->
        File.rm(Path.join(dir, name))

      {:ok, current} when is_binary(current) and current != "0" and current != start ->
        File.rm(Path.join(dir, name))

      _ ->
        :ok
    end
  end

  defp owner_from_name(name) do
    case Regex.run(~r/^agent-reaper-(\d+)-(\d+)(?:\.bin(?:\.bad-\d+)?|-\d+\.tmp)$/, name) do
      [_, pid, start] -> {String.to_integer(pid), start}
      _ -> nil
    end
  end

  defp merge(records, identities) do
    Enum.reduce(identities, records, fn
      {pid, starttime}, acc when is_integer(pid) and is_binary(starttime) ->
        [{pid, starttime} | Enum.reject(acc, fn {existing, _} -> existing == pid end)]

      _other, acc ->
        acc
    end)
  end

  defp verify(records) do
    Enum.filter(records, fn
      {pid, starttime} when is_integer(pid) and is_binary(starttime) ->
        AgentLink.Agent.Process.same_start?(pid, starttime)

      _ ->
        false
    end)
  end

  defp load(path) do
    case File.read(path) do
      {:error, :enoent} ->
        []

      {:error, reason} ->
        discard(path, reason)
        []

      {:ok, binary} ->
        case decode(binary) do
          {:ok, records} ->
            records

          :corrupt ->
            discard(path, :corrupt)
            []
        end
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {:agentlink_reaper, @version, records} when is_list(records) -> {:ok, records}
      _ -> :corrupt
    end
  rescue
    ArgumentError -> :corrupt
  end

  defp discard(path, reason) do
    dest = path <> ".bad-" <> Integer.to_string(System.unique_integer([:positive]))

    Logger.error(
      "agent reaper discarded #{path} (#{inspect(reason)}). The bytes were not used to signal a process."
    )

    case File.rename(path, dest) do
      :ok -> :ok
      {:error, rename} -> Logger.error("agent reaper could not move #{path}: #{inspect(rename)}")
    end
  end

  defp save(vm, records) do
    path = record_path(vm)
    File.mkdir_p!(Path.dirname(path))
    tmp = tmp_path(vm)
    data = :erlang.term_to_binary({:agentlink_reaper, @version, records})
    {:ok, fd} = :file.open(to_charlist(tmp), [:write, :binary, {:mode, 0o600}])

    try do
      :ok = :file.write(fd, data)
    after
      :file.close(fd)
    end

    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    records
  end

  defp tmp_path({pid, start}) do
    uniq = System.unique_integer([:positive])
    Path.join(directory(), "agent-reaper-#{pid}-#{start}-#{uniq}.tmp")
  end
end
