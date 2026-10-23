defmodule Pont.Relay.Agent do
  @moduledoc """
  Supervised owner of one `Pont.Agent`.

  Stdout is ACP JSONL. The agent is linked to this process: when it
  exits, this process stops and its supervisor starts another one. Production
  uses `Pont.OpenCode`. The module comes from `:pont, :agent_module`.
  """

  use GenServer
  require Logger

  defstruct [:agent, :agent_module, buffer: ""]

  @doc "Own the agent. If it dies, the supervisor starts this process again."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    cwd = Pont.Paths.workdir()
    File.mkdir_p!(cwd)
    agent_module = Application.get_env(:pont, :agent_module, Pont.OpenCode)
    {:ok, agent} = agent_module.open(self(), cwd)
    Logger.info("agent relay supervising #{inspect(agent_module)} cwd=#{cwd} agent=#{inspect(agent)}")

    case Pont.Uplink.start_link(owner: self()) do
      {:ok, _} ->
        {:ok, %__MODULE__{agent: agent, agent_module: agent_module}}

      {:error, reason} ->
        agent_module.close(agent)
        {:stop, reason}
    end
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
            Pont.Uplink.send_message(message)

          _ ->
            Logger.warning("agent relay dropped non-json stdout")
        end
      end
    end)

    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({agent, {:exit_status, status}}, %__MODULE__{agent: agent} = state) do
    Logger.error("agent exited status=#{status}, supervisor will restart the agent relay")
    {:stop, {:agent_exit, status}, state}
  end

  def handle_info({:EXIT, agent, reason}, %__MODULE__{agent: agent} = state) do
    Logger.error("agent exit #{inspect(reason)}")
    {:stop, {:agent_exit, reason}, state}
  end

  def handle_info({:from_plane, message}, state) when is_map(message) do
    write(state, message)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, {:shutdown, message}}, %__MODULE__{agent: agent} = state)
      when pid != agent and is_binary(message) do
    Logger.error(message)
    {:stop, {:shutdown, message}, state}
  end

  def handle_info({:EXIT, pid, reason}, %__MODULE__{agent: agent} = state) when pid != agent do
    Logger.error("uplink exit #{inspect(reason)}")
    {:ok, _} = Pont.Uplink.start_link(owner: self())
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("agent relay ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %__MODULE__{agent: agent, agent_module: agent_module}) do
    Logger.info("agent relay stopping #{inspect(reason)}")
    agent_module.close(agent)
    :ok
  end

  defp write(%{agent_module: agent_module, agent: agent}, message) do
    agent_module.write(agent, [Jason.encode!(message), ?\n])
  end

  defp take_lines(buffer), do: take_lines(buffer, [])

  defp take_lines(buffer, acc) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> take_lines(rest, [String.trim(line) | acc])
      _ -> {Enum.reverse(acc), buffer}
    end
  end
end
