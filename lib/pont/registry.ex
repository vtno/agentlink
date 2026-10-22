defmodule Pont.Registry do
  @moduledoc """
  Live runtimes. The table outlives a single Plane message: an agent socket is the
  source of truth, and a restart of the plane process can read who is still
  connected. A dead agent socket is removed by the monitor.
  """

  use GenServer
  require Logger

  @table :pont_runtimes

  defstruct pids: %{}

  @doc "Own the ETS table of who is dialed in."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %__MODULE__{}}
  end

  @doc "An uplink said hello. Claim this name, and replace a previous agent socket that held it."
  def register(pid, name, label) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, pid, name, label})
  end

  @impl true
  def handle_call({:register, pid, name, label}, _from, %__MODULE__{} = state) do
    with {:ok, name} <- normalize_name(name) do
      label = normalize_label(label, name)
      state = drop_pid(state, pid)
      state = replace_name(state, name, pid)
      ref = Process.monitor(pid)
      :ets.insert(@table, {name, label, pid, System.system_time(:second)})
      Logger.info("runtime registered name=#{name} label=#{label}")
      Pont.Plane.runtime_reset(name)
      {:reply, :ok, %{state | pids: Map.put(state.pids, pid, {ref, name})}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %__MODULE__{} = state) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        {:noreply, state}

      {{_ref, name}, pids} ->
        case :ets.lookup(@table, name) do
          [{^name, _, ^pid, _}] ->
            :ets.delete(@table, name)
            Logger.warning("runtime down name=#{name} #{inspect(reason)}")
            Pont.Plane.runtime_down(name)

          _ ->
            :ok
        end

        {:noreply, %{state | pids: pids}}
    end
  end

  @doc "The runtimes currently dialed in. Read from the table, so this does not enter the process."
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {name, label, _pid, connected_at} ->
      %{"name" => name, "label" => label, "connected_at" => connected_at}
    end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc "The agent socket pid registered under this name, or nil."
  def pid(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, _label, pid, _at}] -> pid
      [] -> nil
    end
  end

  defp replace_name(%__MODULE__{} = state, name, pid) do
    case :ets.lookup(@table, name) do
      [{^name, _, old, _}] when old != pid ->
        send(old, :replaced)
        drop_pid(state, old)

      _ ->
        state
    end
  end

  defp drop_pid(%__MODULE__{} = state, pid) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        state

      {{ref, name}, pids} ->
        Process.demonitor(ref, [:flush])

        case :ets.lookup(@table, name) do
          [{^name, _, ^pid, _}] -> :ets.delete(@table, name)
          _ -> :ok
        end

        %{state | pids: pids}
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name = String.trim(name)

    if String.match?(name, ~r/^[a-z0-9][a-z0-9_-]{0,40}$/) do
      {:ok, name}
    else
      {:error, "runtime name must be a short slug"}
    end
  end

  defp normalize_name(_), do: {:error, "runtime name must be a short slug"}

  defp normalize_label(label, name) when is_binary(label) do
    case String.trim(label) do
      "" -> name
      text -> String.slice(text, 0, 80)
    end
  end

  defp normalize_label(_, name), do: name
end
