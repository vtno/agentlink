defmodule AgentLink.FakeSubscribe do
  @moduledoc """
  `AgentLink.Plane.Subscribe` for tests.

  `notified/1` returns the maps passed to `notify/2`, oldest first. `notify/2`
  does not send `{:send, json}` to `:client_pid`. When the client dies,
  `:owner` receives `{:subscription_down, client_id, session_id}` and this
  process exits with `:normal`.
  """

  @behaviour AgentLink.Plane.Subscribe
  use GenServer

  defstruct [:client_pid, :client_id, :session_id, :owner, notified: []]

  @doc """
  Start the subscription.

  `:client_pid` and `:owner` are pids. `:client_id` and `:session_id` are
  binaries. All four are required.
  """
  @impl true
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, initial(opts))
  end

  @impl true
  def init(%__MODULE__{} = state) do
    Process.monitor(state.client_pid)
    {:ok, state}
  end

  @doc """
  Record one ACP object for `notified/1`.

  `notify/2` does not send `{:send, json}` to the client pid.
  """
  @impl true
  def notify(server, message) when is_map(message) do
    GenServer.call(server, {:notify, message})
  end

  @doc "Maps passed to `notify/2`, oldest first."
  @spec notified(term) :: [map]
  def notified(server), do: GenServer.call(server, :notified)

  @impl true
  def handle_call({:notify, message}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | notified: [message | state.notified]}}
  end

  def handle_call(:notified, _from, %__MODULE__{} = state) do
    {:reply, Enum.reverse(state.notified), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{client_pid: pid} = state) do
    send(state.owner, {:subscription_down, state.client_id, state.session_id})
    {:stop, :normal, state}
  end

  @doc """
  End this subscription.

  The process exits with `:normal`. `:owner` receives no message. Returns
  `:ok`, including when the process has already stopped.
  """
  @impl true
  def stop(server) do
    GenServer.stop(server)
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp initial(opts) do
    %__MODULE__{
      client_pid: pid!(opts, :client_pid),
      client_id: binary!(opts, :client_id),
      session_id: binary!(opts, :session_id),
      owner: pid!(opts, :owner)
    }
  end

  defp pid!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_pid(value) do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a pid, got: #{inspect(value)}"
    end
  end

  defp binary!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_binary(value) do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a binary, got: #{inspect(value)}"
    end
  end
end
