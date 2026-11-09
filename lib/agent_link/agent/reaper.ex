defmodule AgentLink.Agent.Reaper do
  @moduledoc """
  Holds OS processes `close/1` could not reap, and blocks the next agent until they are gone.

  The pairs are a file, not the process state. A file survives this process
  exiting. An ETS table owned here would not. `init/1` reads the file and
  drops a pid whose start time no longer matches, so a restart does not signal
  a recycled pid and does not forget a live one. The file is `agent-reaper.bin`
  under `:reaper_dir` when that is set, otherwise under `RELEASE_TMP`, otherwise
  under `~/.agentlink/run`.

  This process starts before `AgentLink.Relay.Agent` in the same supervisor.
  `retain/1` stores `{pid, starttime}` pairs. `reap/0` signals `SIGKILL` to
  each pair whose start time still matches and waits `1000` milliseconds.
  `:ok` means every retained start time is gone. `{:error, :timeout}` means
  one still matches. `{:error, :no_kill}` means `kill` is not on `PATH` and a
  retained process is still alive. `{:error, :kill_failed}` means `kill`
  exited non-zero and that start time still matches. `{:error, :noproc}` means
  this process is not running. The next relay calls `reap/0` before `open/3`
  and does not open an agent when the result is an error.
  """

  use GenServer

  @filename "agent-reaper.bin"

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 2_000
    }
  end

  @doc "Start the reaper. The record file is loaded and checked against `/proc`."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    records = record_path() |> load() |> verify()
    save(records)
    {:ok, records}
  end

  @doc """
  Remember processes whose start time still matches.

  Returns `{:error, :noproc}` when this process is not running.
  """
  @spec retain([{integer(), String.t()}]) :: :ok | {:error, :noproc}
  def retain(identities) when is_list(identities) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:retain, identities})
      _ -> {:error, :noproc}
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

  @doc false
  def record_path do
    dir =
      Application.get_env(:agent_link, :reaper_dir) ||
        System.get_env("RELEASE_TMP") ||
        Path.join(AgentLink.Paths.root(), "run")

    Path.join(dir, @filename)
  end

  @impl true
  def handle_call({:retain, identities}, _from, state) do
    state = state |> merge(identities) |> verify()
    save(state)
    {:reply, :ok, state}
  end

  def handle_call(:reap, _from, state) do
    state = verify(state)

    case AgentLink.Agent.Process.force(state) do
      :ok ->
        save([])
        {:reply, :ok, []}

      {:error, reason} ->
        state = verify(state)
        save(state)
        {:reply, {:error, reason}, state}
    end
  end

  defp merge(state, identities) do
    Enum.reduce(identities, state, fn
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
      {:ok, binary} -> decode(binary)
      {:error, :enoent} -> []
      {:error, reason} -> raise "agent reaper could not read #{path}: #{inspect(reason)}"
    end
  end

  defp decode(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      records when is_list(records) -> records
      _ -> raise ArgumentError, "agent reaper record is not a list"
    end
  end

  defp save(records) do
    path = record_path()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(records))
    File.rename!(tmp, path)
    records
  end
end
