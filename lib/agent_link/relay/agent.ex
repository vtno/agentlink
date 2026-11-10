defmodule AgentLink.Relay.Agent do
  @moduledoc """
  Supervised owner of one `AgentLink.Agent`.

  Stdout is ACP JSONL. `AgentLink.Frame` splits it. The agent is linked to
  this process: when it exits, this process stops and its supervisor starts
  another one. Each start creates the workspace, then calls
  `AgentLink.Agent.Launch.load/1` once. That call returns the link and the
  launch. The link is the uplink's initial snapshot. The launch is passed
  to `open/5` for `AgentLink.Agent.Process` and to `open/3` for any other
  module. The next start reads the file again. The launch is not a
  supervisor child argument. The module comes from `:agent_link,
  :agent_module`. The default is `AgentLink.Agent.Process`.

  `start_link/1` accepts `:transport`, `:transport_opts`, and
  `:watch_interval`. The defaults are `AgentLink.Transport.WebSocket`, `[]`,
  and `1_000`. Those options are not the launch.

  For `session/new` and `session/load`, a missing, null, or empty `cwd`
  in params is filled with `AgentLink.Paths.workdir()` before the message is
  written to the agent. An explicit `cwd` passes through unchanged.

  The child shutdown is the `SIGTERM` wait, the confirmation wait, and two
  allowances of `1000` milliseconds for the `kill` commands, read when the
  child spec is built. The allowance is `AgentLink.Agent.Process.allowance_ms/0`.
  The `SIGTERM` wait is `:agent_stop_timeout`. The confirmation wait is
  `:agent_stop_timeout`, or `1000` when that is shorter. The default
  `:agent_stop_timeout` is `5000`, so the shutdown is `12000`.
  `terminate/2` calls `close/1` and does not return until that call returns.
  `init/1` calls `AgentLink.Agent.Reaper.reap/0` before `open/5` for
  `AgentLink.Agent.Process`. A failed
  reap stops this start, so no replacement agent is spawned while a retained
  start time is still alive.
  """

  use GenServer
  require Logger

  defstruct [:agent, :agent_module, :uplink, buffer: ""]

  # A dropped stdout line can be huge, or not valid UTF-8. Log a prefix.
  @dropped_bytes 80

  @doc false
  def child_spec(opts) do
    timeout = Application.get_env(:agent_link, :agent_stop_timeout, 5_000)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: shutdown_ms(timeout)
    }
  end

  defp shutdown_ms(timeout) do
    allowance = AgentLink.Agent.Process.allowance_ms()
    timeout + max(timeout, allowance) + allowance * 2
  end

  @doc """
  Own the agent. If it dies, the supervisor starts this process again.

  `:transport` defaults to `AgentLink.Transport.WebSocket`. `:transport_opts`
  defaults to `[]`. `:watch_interval` defaults to `1_000`. `nil` does not
  schedule link-file reads. This process reads the launch with
  `AgentLink.Agent.Launch.load/1` when it starts. These options are not the launch.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case AgentLink.Agent.Reaper.reap() do
      :ok ->
        boot(opts)

      {:error, reason} ->
        Logger.error("agent reap failed: #{inspect(reason)}")
        {:stop, {:reap, reason}}
    end
  end

  defp boot(opts) do
    cwd = AgentLink.Paths.workdir()
    File.mkdir_p!(cwd)
    agent_module = Application.get_env(:agent_link, :agent_module, AgentLink.Agent.Process)
    uplink = uplink_opts(opts)

    case AgentLink.Agent.Launch.load() do
      {:ok, link, launch} ->
        open_agent(agent_module, launch, cwd, link, uplink)

      {:error, message} when is_binary(message) ->
        {:stop, {:shutdown, message}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @doc "Write one ACP message to the agent's stdin. For `session/new` and `session/load`, a missing, null, or empty `cwd` is filled with `AgentLink.Paths.workdir()` first. :down if this process is gone."
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
    {items, rest} = AgentLink.Frame.take(state.buffer, data)

    Enum.each(items, fn
      {:ok, message} ->
        AgentLink.Uplink.send_message(message)

      {:error, line} ->
        Logger.warning("agent relay dropped non-json stdout #{inspect(dropped_prefix(line))}")
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
    {:ok, _} = AgentLink.Uplink.start_link(state.uplink)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("agent relay ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %__MODULE__{agent: agent, agent_module: agent_module}) do
    Logger.info("agent relay stopping #{inspect(reason)}")

    case agent_module.close(agent) do
      :ok ->
        :ok

      {:error, stop_reason} ->
        Logger.error("agent stop failed: #{inspect(stop_reason)}")
        :ok
    end
  end

  defp uplink_opts(opts) do
    [
      owner: self(),
      transport: Keyword.get(opts, :transport, AgentLink.Transport.WebSocket),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      watch_interval: Keyword.get(opts, :watch_interval, 1_000)
    ]
  end

  defp open_agent(agent_module, launch, cwd, link, uplink) do
    case open_launch(agent_module, launch, cwd) do
      {:ok, agent} ->
        dial(agent_module, agent, link, uplink, cwd)

      {:error, message} when is_binary(message) ->
        {:stop, {:shutdown, message}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp open_launch(AgentLink.Agent.Process, launch, cwd) do
    AgentLink.Agent.Process.open(
      self(),
      launch,
      cwd,
      &System.find_executable/1,
      Application.get_env(:agent_link, :agent_open_listener)
    )
  end

  defp open_launch(agent_module, launch, cwd) do
    agent_module.open(self(), launch, cwd)
  end

  defp dial(agent_module, agent, link, uplink, cwd) do
    case AgentLink.Uplink.start_link([{:link, link} | uplink]) do
      {:ok, _} ->
        Logger.info("opened #{inspect(agent_module)} cwd=#{cwd} agent=#{inspect(agent)}")

        {:ok, %__MODULE__{agent: agent, agent_module: agent_module, uplink: uplink}}

      {:error, reason} ->
        agent_module.close(agent)
        {:stop, reason}

      :ignore ->
        agent_module.close(agent)
        {:stop, :ignore}
    end
  end

  defp write(%{agent_module: agent_module, agent: agent}, message) do
    message = default_cwd(message)
    agent_module.write(agent, AgentLink.Frame.encode_line(message))
  end

  defp default_cwd(%{"method" => method} = message)
       when method in ["session/new", "session/load"] do
    params = Map.get(message, "params", %{})

    if is_map(params) and Map.get(params, "cwd") in [nil, ""] do
      Map.put(message, "params", Map.put(params, "cwd", AgentLink.Paths.workdir()))
    else
      message
    end
  end

  defp default_cwd(message), do: message

  defp dropped_prefix(line) do
    binary_part(line, 0, min(@dropped_bytes, byte_size(line)))
  end
end
