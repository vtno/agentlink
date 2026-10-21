defmodule Acp.Sidecar do
  @moduledoc """
  Supervised owner of one agent harness.

  Stdout is ACP JSONL. The harness is linked to this process: when the agent
  exits, this process stops and `Acp.Supervisor` starts another one. Production
  uses `Acp.OpenCode`. The module comes from `:acp, :harness`.
  """

  use GenServer
  require Logger

  defstruct [:agent, :harness, buffer: ""]

  @doc "Own the agent harness. If it dies, the supervisor starts this process again."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    cwd = Application.fetch_env!(:acp, :workdir)
    File.mkdir_p!(cwd)
    harness = Application.get_env(:acp, :harness, Acp.OpenCode)
    {:ok, agent} = harness.open(self(), cwd)
    Logger.info("sidecar supervising #{inspect(harness)} cwd=#{cwd} agent=#{inspect(agent)}")
    {:ok, _} = Acp.Uplink.start_link(owner: self())

    {:ok, %__MODULE__{agent: agent, harness: harness}}
  end

  @doc "Write one ACP message to the agent's stdin. :down if this process is gone."
  @spec send_message(map()) :: :ok | :down
  def send_message(message) when is_map(message) do
    case Process.whereis(__MODULE__) do
      nil -> :down
      pid -> GenServer.cast(pid, {:send, message})
    end
  end

  @impl true
  def handle_cast({:send, message}, state) do
    case write(state, message) do
      :ok -> {:noreply, state}
      :closed -> {:stop, :port_closed, state}
    end
  end

  @impl true
  def handle_info({agent, {:data, data}}, %__MODULE__{agent: agent} = state) do
    {lines, rest} = take_lines(state.buffer <> data)

    Enum.each(lines, fn line ->
      if line != "" do
        case Jason.decode(line) do
          {:ok, message} when is_map(message) ->
            Acp.Uplink.send_message(message)

          _ ->
            Logger.warning("sidecar dropped non-json stdout")
        end
      end
    end)

    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({agent, {:exit_status, status}}, %__MODULE__{agent: agent} = state) do
    Logger.error("agent exited status=#{status}, supervisor will restart the sidecar")
    {:stop, {:opencode_exit, status}, state}
  end

  def handle_info({:EXIT, agent, reason}, %__MODULE__{agent: agent} = state) do
    Logger.error("agent exit #{inspect(reason)}")
    {:stop, {:opencode_exit, reason}, state}
  end

  def handle_info({:from_plane, message}, state) when is_map(message) do
    write(state, message)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %__MODULE__{agent: agent} = state) when pid != agent do
    Logger.error("uplink exit #{inspect(reason)}")
    {:ok, _} = Acp.Uplink.start_link(owner: self())
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("sidecar ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %__MODULE__{agent: agent, harness: harness}) do
    Logger.info("sidecar stopping #{inspect(reason)}")
    harness.close(agent)
    :ok
  end

  defp write(%{harness: harness, agent: agent}, message) do
    harness.write(agent, [Jason.encode!(message), ?\n])
  end

  defp take_lines(buffer), do: take_lines(buffer, [])

  defp take_lines(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> take_lines(rest, [String.trim(line) | acc])
      _ -> {Enum.reverse(acc), buffer}
    end
  end
end
