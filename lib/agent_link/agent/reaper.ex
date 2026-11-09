defmodule AgentLink.Agent.Reaper do
  @moduledoc """
  Holds OS processes `close/1` could not reap, and blocks the next agent until they are gone.

  The pairs are a file, not this process's memory. The file only has to survive
  a restart of this process inside one VM. Its name is
  `agent-reaper-<pid>-<starttime>.bin`, using this VM's OS pid and the start
  time from `/proc/<pid>/stat`. The directory is `:reaper_dir` when that is
  set, otherwise `RELEASE_TMP`, otherwise `~/.agentlink/run`. Two VMs that
  share the directory do not read or signal each other's pairs. A file whose
  owning VM is gone is removed. This VM's file is removed on a clean shutdown.
  Each write uses its own temporary name and mode `0600`.

  The term is `{:agentlink_reaper, 1, pairs}`. A short, undecodable, non-list,
  or other-version file is not trusted: it is logged, renamed beside the
  record, and this process starts with no pairs from it. Those bytes are not
  used to signal a process, and they do not block the next open, because the
  pairs cannot be read.

  This process starts before `AgentLink.Relay.Agent` in the same supervisor.
  `retain/1` stores `{pid, starttime}` pairs. When this process is not
  running, `retain/1` still writes the pairs into this VM's file and returns
  `{:error, :noproc}`. `reap/0` reads that file again, signals `SIGKILL` to
  each pair whose start time still matches, and waits `1000` milliseconds.
  `:ok` means every retained start time is gone. `{:error, :timeout}` means
  one still matches. `{:error, :no_kill}` means `kill` is not on `PATH` and a
  retained process is still alive. `{:error, :kill_failed}` means `kill`
  exited non-zero and that start time still matches. The next relay calls
  `reap/0` before `open/3` and does not open an agent when the result is an error.
  """

  use GenServer

  require Logger

  @version 1
  @type owner :: {integer(), String.t()}

  defstruct [:owner, records: []]

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 2_000
    }
  end

  @doc "Start the reaper. This VM's record file is loaded and checked against `/proc`."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, server_opts(opts))
  end

  @impl true
  def init(opts) do
    owner = owner_opt(opts)
    dir = directory()
    File.mkdir_p!(dir)
    sweep_stale(dir, owner)
    records = load(record_path(owner))
    save(owner, records)
    {:ok, %__MODULE__{owner: owner, records: records}}
  end

  @doc """
  Remember processes whose start time still matches.

  Returns `{:error, :noproc}` when this process is not running. The pairs are
  still written to this VM's file, so the next `reap/0` sees them.
  """
  @spec retain([{integer(), String.t()}]) :: :ok | {:error, :noproc}
  def retain(identities) when is_list(identities) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:retain, identities})
      _ -> absent_retain(identities)
    end
  end

  @doc """
  SIGKILL every retained process and wait until its start time is gone.

  Returns `{:error, :noproc}` when this process is not running.
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
    records = state.records |> merge(identities) |> verify()
    save(state.owner, records)
    {:reply, :ok, %{state | records: records}}
  end

  def handle_call(:reap, _from, %__MODULE__{} = state) do
    records =
      state.owner
      |> record_path()
      |> load()
      |> merge(state.records)
      |> verify()

    case AgentLink.Agent.Process.force(records) do
      :ok ->
        save(state.owner, [])
        {:reply, :ok, %{state | records: []}}

      {:error, reason} ->
        records = verify(records)
        save(state.owner, records)
        {:reply, {:error, reason}, %{state | records: records}}
    end
  end

  @impl true
  def terminate(reason, %__MODULE__{owner: owner}) do
    if clean?(reason), do: File.rm(record_path(owner))
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
    save(vm_owner(), pairs)
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

  defp owner_opt(opts) do
    case Keyword.get(opts, :owner, vm_owner()) do
      {pid, start} when is_integer(pid) and pid > 0 and is_binary(start) ->
        {pid, start}

      other ->
        raise ArgumentError, "reaper owner must be {pid, starttime}, got: #{inspect(other)}"
    end
  end

  defp absent_retain(identities) do
    if pair?(identities) do
      owner = vm_owner()
      records = owner |> record_path() |> load() |> merge(identities) |> verify()
      save(owner, records)
    end

    {:error, :noproc}
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

  defp sweep_stale(dir, owner) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          case owner_from_name(name) do
            ^owner -> :ok
            {pid, _start} = other when is_integer(pid) -> maybe_drop(dir, name, other)
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp maybe_drop(dir, name, {pid, start}) do
    unless AgentLink.Agent.Process.same_start?(pid, start) do
      File.rm(Path.join(dir, name))
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

  defp save(owner, records) do
    path = record_path(owner)
    File.mkdir_p!(Path.dirname(path))
    tmp = tmp_path(owner)
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
