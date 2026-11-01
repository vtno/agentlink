defmodule AgentLink.Plane.Subscription do
  @moduledoc """
  Production `AgentLink.Plane.Subscribe`. One process for a session a client
  has open.

  `notify/2` sends `{:send, json}` to `:client_pid`. `json` is
  `AgentLink.Frame.encode/1` of the map. `AgentLink.ClientSocket` pushes
  `{:send, json}`.

  When `:client_pid` dies, `:owner` receives
  `{:subscription_down, client_id, session_id}` and this process exits with
  `:normal`. `stop/1` exits the same way and sends no message to `:owner`.
  The plane does not start this process.
  """

  @behaviour AgentLink.Plane.Subscribe
  use GenServer

  defstruct [:client_pid, :client_id, :session_id, :owner]

  @doc """
  Start the subscription for one session this client has open.

  `:client_pid` and `:owner` are pids. `:client_id` and `:session_id` are
  binaries. All four are required. When the client dies, `:owner` receives
  `{:subscription_down, client_id, session_id}` and this process exits with
  `:normal`, so the linked caller keeps running.
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
  Send one ACP object to the client.

  The client receives `{:send, json}`. `json` is `AgentLink.Frame.encode/1`
  of the map. `AgentLink.ClientSocket` pushes that message.
  """
  @impl true
  def notify(server, message) when is_map(message) do
    GenServer.call(server, {:notify, message})
  end

  @impl true
  def handle_call({:notify, message}, _from, %__MODULE__{} = state) do
    send(state.client_pid, {:send, AgentLink.Frame.encode(message)})
    {:reply, :ok, state}
  end

  @doc """
  End this client's subscription.

  The session calls this when the client sends `session/close`. The process
  exits with `:normal`. `:owner` receives no message. Returns `:ok`, including
  when the process has already stopped.
  """
  @impl true
  def stop(server) do
    GenServer.stop(server)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{client_pid: pid} = state) do
    send(state.owner, {:subscription_down, state.client_id, state.session_id})
    {:stop, :normal, state}
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
