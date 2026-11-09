defmodule AgentLink.Agent.Reaper do
  @moduledoc """
  Holds OS processes `close/1` could not reap, and blocks the next agent until they are gone.

  This process starts before `AgentLink.Relay.Agent` in the same supervisor, so a
  relay restart leaves the record in place. `retain/1` stores `{pid, starttime}`
  pairs. `reap/0` signals `SIGKILL` to each pair whose start time still matches
  and waits `1000` milliseconds. `:ok` means every retained start time is gone.
  `{:error, :timeout}` means one still matches. `{:error, :no_kill}` means `kill`
  is not on `PATH` and a retained process is still alive. `{:error, :kill_failed}`
  means `kill` exited non-zero and that start time still matches. The next relay
  calls `reap/0` before `open/3` and does not open an agent when the result is an error.
  """

  use GenServer

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 2_000
    }
  end

  @doc "Start the reaper. A relay restart does not restart this process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, []}
  end

  @doc "Remember processes whose start time still matches. `:ok` when no reaper is running."
  @spec retain([{integer(), String.t()}]) :: :ok
  def retain(identities) when is_list(identities) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:retain, identities})
      _ -> :ok
    end
  end

  @doc "SIGKILL every retained process and wait until its start time is gone."
  @spec reap() :: :ok | {:error, :timeout | :no_kill | :kill_failed}
  def reap do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :reap, 10_000)
      _ -> :ok
    end
  end

  @impl true
  def handle_call({:retain, identities}, _from, state) do
    {:reply, :ok, merge(state, identities)}
  end

  def handle_call(:reap, _from, state) do
    case AgentLink.Agent.Process.force(state) do
      :ok -> {:reply, :ok, []}
      {:error, reason} -> {:reply, {:error, reason}, state}
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
end
