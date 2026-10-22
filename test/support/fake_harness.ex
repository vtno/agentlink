defmodule Pont.FakeHarness do
  @moduledoc false
  @behaviour Pont.Harness
  use GenServer

  def emit(agent, data) when is_pid(agent), do: send(agent, {:emit, data})
  def exit_status(agent, status) when is_pid(agent), do: send(agent, {:status, status})
  def refuse(agent) when is_pid(agent), do: GenServer.cast(agent, :refuse)

  @impl true
  def open(owner, cwd) do
    {:ok, pid} = GenServer.start_link(__MODULE__, owner)
    if listener = Application.get_env(:pont, :harness_listener), do: send(listener, {:harness_opened, pid, cwd})
    {:ok, pid}
  end

  @impl true
  def write(pid, data) when is_pid(pid) do
    GenServer.call(pid, {:write, IO.iodata_to_binary(data)})
  catch
    :exit, _ -> :closed
  end

  def write(_ref, _data), do: :closed

  @impl true
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  def close(_ref), do: :ok

  @impl true
  def init(owner), do: {:ok, %{owner: owner, refuse: false}}

  @impl true
  def handle_call({:write, _data}, _from, %{refuse: true} = state), do: {:reply, :closed, state}

  def handle_call({:write, data}, _from, state) do
    if listener = Application.get_env(:pont, :harness_listener), do: send(listener, {:harness_write, data})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:refuse, state), do: {:noreply, %{state | refuse: true}}

  @impl true
  def handle_info({:emit, data}, %{owner: owner} = state) do
    send(owner, {self(), {:data, data}})
    {:noreply, state}
  end

  def handle_info({:status, status}, %{owner: owner} = state) do
    send(owner, {self(), {:exit_status, status}})
    {:noreply, state}
  end

  def handle_info(:close, state), do: {:stop, :normal, state}
end
