defmodule AgentLink.FakeAgent do
  @moduledoc false
  @behaviour AgentLink.Agent
  use GenServer

  defstruct [:owner, refuse: false]

  @impl true
  def open(owner, cwd) do
    {:ok, pid} = GenServer.start_link(__MODULE__, owner)

    if listener = Application.get_env(:agent_link, :agent_listener),
      do: send(listener, {:agent_opened, pid, cwd})

    {:ok, pid}
  end

  @impl true
  def init(owner), do: {:ok, %__MODULE__{owner: owner}}

  @impl true
  def write(pid, data) when is_pid(pid) do
    GenServer.call(pid, {:write, IO.iodata_to_binary(data)})
  catch
    :exit, _ -> :closed
  end

  def write(_ref, _data), do: :closed

  @impl true
  def handle_call({:write, _data}, _from, %__MODULE__{refuse: true} = state),
    do: {:reply, :closed, state}

  def handle_call({:write, data}, _from, %__MODULE__{} = state) do
    if listener = Application.get_env(:agent_link, :agent_listener),
      do: send(listener, {:agent_write, data})

    {:reply, :ok, state}
  end

  def refuse(agent) when is_pid(agent), do: GenServer.cast(agent, :refuse)

  @impl true
  def handle_cast(:refuse, %__MODULE__{} = state), do: {:noreply, %{state | refuse: true}}

  def emit(agent, data) when is_pid(agent), do: send(agent, {:emit, data})
  def exit_status(agent, status) when is_pid(agent), do: send(agent, {:status, status})

  @impl true
  def handle_info({:emit, data}, %__MODULE__{owner: owner} = state) do
    send(owner, {self(), {:data, data}})
    {:noreply, state}
  end

  def handle_info({:status, status}, %__MODULE__{owner: owner} = state) do
    send(owner, {self(), {:exit_status, status}})
    {:noreply, state}
  end

  def handle_info(:close, %__MODULE__{} = state), do: {:stop, :normal, state}

  @impl true
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  def close(_ref), do: :ok
end
