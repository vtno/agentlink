defmodule AgentLink.FakeStdio do
  @moduledoc """
  In-process `AgentLink.Stdio` for tests. No port.

  `emit/2` delivers bytes to the owner as `{pid, {:data, binary}}`. `eof/1`
  delivers `{pid, :eof}`. `written/1` is the iodata passed to `write/2`, oldest
  first, as binaries.
  `refuse/1` makes the next `write/2` return `:closed`.

  This process traps exits. The owner dying does not stop it. `close/1` does,
  so a test can see that the client relay closed stdio.
  """

  @behaviour AgentLink.Stdio
  use GenServer

  defstruct [:owner, written: [], refuse: false]

  @impl true
  def open(owner) when is_pid(owner) do
    GenServer.start_link(__MODULE__, owner)
  end

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{owner: owner}}
  end

  @impl true
  def write(pid, data) when is_pid(pid) do
    GenServer.call(pid, {:write, IO.iodata_to_binary(data)})
  catch
    :exit, _ -> :closed
  end

  def write(_term, _data), do: :closed

  @doc "Bytes the owner has written, oldest first."
  def written(pid) when is_pid(pid), do: GenServer.call(pid, :written)

  @doc "The next write returns `:closed`."
  def refuse(pid) when is_pid(pid), do: GenServer.call(pid, :refuse)

  @doc "Deliver one chunk to the owner."
  def emit(pid, data) when is_pid(pid) and is_binary(data) do
    GenServer.call(pid, {:emit, data})
  end

  @doc "Deliver end of stdin to the owner."
  def eof(pid) when is_pid(pid), do: GenServer.call(pid, :eof)

  @impl true
  def handle_call({:write, _data}, _from, %__MODULE__{refuse: true} = state) do
    {:reply, :closed, state}
  end

  def handle_call({:write, data}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | written: [data | state.written]}}
  end

  def handle_call(:written, _from, %__MODULE__{} = state) do
    {:reply, Enum.reverse(state.written), state}
  end

  def handle_call(:refuse, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | refuse: true}}
  end

  def handle_call({:emit, data}, _from, %__MODULE__{} = state) do
    send(state.owner, {self(), {:data, data}})
    {:reply, :ok, state}
  end

  def handle_call(:eof, _from, %__MODULE__{} = state) do
    send(state.owner, {self(), :eof})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, %__MODULE__{} = state), do: {:noreply, state}

  @impl true
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  def close(_term), do: :ok
end
