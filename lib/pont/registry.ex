defmodule Pont.Registry.Uplink do
  @moduledoc """
  One dialed sidecar. `name` comes from the link. `label` is the machine.
  `program` is the agent product name, not the `Pont.Harness` module.
  """

  defstruct [:name, :label, :program, :pid, :connected_at]
end

defmodule Pont.Registry do
  @moduledoc """
  Live uplinks. One row is one sidecar that has said hello.
  The socket is the source of truth.
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

  @doc "An uplink said hello. The access policy accepts this subject, then this table remembers the socket."
  def register(pid, %Pont.Registry.Uplink{} = uplink, %Pont.Access.Subject{} = subject) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, pid, uplink, subject})
  end

  @impl true
  def handle_call({:register, pid, %Pont.Registry.Uplink{} = uplink, subject}, _from, %__MODULE__{} = state) do
    with {:ok, name} <- normalize_name(uplink.name),
         :ok <- Pont.Access.claim(subject, name) do
      uplink = %Pont.Registry.Uplink{
        name: name,
        label: clip(uplink.label, name),
        program: clip(uplink.program, "opencode"),
        pid: pid,
        connected_at: System.system_time(:second)
      }

      state = drop_pid(state, pid)
      state = replace_name(state, name, pid)
      ref = Process.monitor(pid)
      :ets.insert(@table, {name, uplink})
      Logger.info("uplink registered name=#{uplink.name} label=#{uplink.label} program=#{uplink.program}")
      Pont.Setup.Watch.connected(uplink.name, uplink.label)
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
          [{^name, %Pont.Registry.Uplink{pid: ^pid}}] ->
            :ets.delete(@table, name)
            Logger.warning("runtime down name=#{name} #{inspect(reason)}")
            Pont.Plane.runtime_down(name)

          _ ->
            :ok
        end

        {:noreply, %{state | pids: pids}}
    end
  end

  @doc "The uplinks this subject may use."
  def allowed(%Pont.Access.Subject{} = subject) do
    Enum.filter(list(), &Pont.Access.allowed?(subject, &1["name"]))
  end

  @doc "The uplinks currently dialed in. `name` is what a client selects."
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, %Pont.Registry.Uplink{} = uplink} ->
      %{
        "name" => uplink.name,
        "label" => uplink.label,
        "program" => uplink.program,
        "connected_at" => uplink.connected_at
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc "The agent socket pid registered under this link name, or nil."
  def pid(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, %Pont.Registry.Uplink{pid: pid}}] -> pid
      [] -> nil
    end
  end

  defp replace_name(%__MODULE__{} = state, name, pid) do
    case :ets.lookup(@table, name) do
      [{^name, %Pont.Registry.Uplink{pid: old}}] when old != pid ->
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
          [{^name, %Pont.Registry.Uplink{pid: ^pid}}] -> :ets.delete(@table, name)
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
      {:error, "link name must be a short slug"}
    end
  end

  defp normalize_name(_), do: {:error, "link name must be a short slug"}

  defp clip(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      text -> String.slice(text, 0, 80)
    end
  end

  defp clip(_value, fallback), do: fallback
end
