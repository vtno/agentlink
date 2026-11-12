defmodule AgentLink.Application do
  @moduledoc """
  `agentlink` runs the plane and the relay in one BEAM. `agentlink plane` and
  `agentlink relay` split them onto two machines. They still talk over the agent
  WebSocket. The link file holds the name, the label, the program, and the plane URL.
  `command` and `args` in that file are the launch. `program` is metadata.

  `start/2` starts `AgentLink.Supervisor` with `Supervisor.start_link/2` in the
  calling process. That process is the supervisor's parent and stays linked to
  it. In a release, the caller is the process `application_master` uses to stop
  the application, so `Application.stop/1`, `bin/agentlink stop`, and `SIGTERM`
  shut the tree down.

  `agentlink plane` and `agentlink connect` do not read the link file. `agentlink`
  and `agentlink relay` read it in `AgentLink.Relay.Agent.init/1`. When that start
  fails and the reason unwraps to a binary message, the command prints the message
  once and exits with status 1. The unwrap accepts `{:shutdown, reason}` and
  `{:failed_to_start_child, id, reason}`. A failure that does not end in a binary
  message stays a supervisor error. In the test environment, `start/2` returns
  `{:error, message}` instead of halting.

  `agentlink connect` starts `AgentLink.Relay.Client` as the only supervisor
  child. It does not start the plane, the agent relay, or a link-file check,
  and it does not run `AgentLink.Setup.prepare/0`. `AgentLink.Config.load/1`
  reads the plane URL, the target, and the token. `--plane`, `--target`, and
  `--token` are stored as `:connect_plane`, `:connect_target`, and
  `:connect_token`. A flag that has text wins over the environment variable,
  and an environment variable that has text wins over the file.
  `:config_root` is the `:root`
  passed to `load/1`, default `AgentLink.Paths.root/0`. `:config_env` is the
  `:env` passed to `load/1`, default `System.get_env/0`. `:connect_transport`
  and `:connect_stdio` override the client relay defaults when they are set.

  When the plane URL is missing, the token is missing, or the client relay
  fails to start, the command prints the error and exits with status 1.
  In the test environment, `start/2` returns `{:error, message}` instead of
  halting. When the client relay stops with `{:shutdown, "stdio closed"}`,
  the command exits with status 0. That includes stdin that is already closed
  when the client relay starts. `start_client/2` is the child start function.
  `boot_client/2` has the watcher monitor that pid before the client relay
  handles stdin. The watcher is linked to the process that called `start/2`.
  Any other `{:shutdown, message}` exits with status 1. The
  supervisor starts the client relay again after a crash because
  `AgentLink.Relay.Client.child_spec/1` sets `restart: :transient`. The
  supervisor's own stop exits with status 1. `agentlink connect` replaces
  `:erl_signal_handler` with `AgentLink.ConnectStop`. That handler logs the
  `SIGTERM` notice and calls `:init.stop/1`. The watcher does not call
  `System.halt/1` once `:init.get_status/0` is `:stopping`, so the status
  stays 1. A stop that is not a signal flushes the log and halts. The test
  environment does not install the handler.
  In the test environment,
  `:halt_listener` receives `{:connect_watching, pid}` after the watcher
  monitors the client relay, `{:connect_supervisor, pid}` after the watcher
  monitors `AgentLink.Supervisor`, and `{:connect_exit, code}` instead of
  halting.
  """

  use Application

  # A release has no Mix. A bad command must exit. A crash dump is the wrong signal.
  @halt_boot_error Mix.env() != :test

  @impl true
  def start(_type, _args) do
    with :ok <- command(),
         :ok <- prepare(),
         :ok <- install_connect_stop(),
         {:ok, children} <- children() do
      children
      |> start_supervisor()
      |> watch_connect()
    end
  end

  defp command do
    if Application.get_env(:agent_link, :cli, true) do
      case AgentLink.CLI.apply() do
        :ok -> :ok
        {:halt, code} -> System.halt(code)
        {:error, message} -> boot_error(message)
      end
    else
      :ok
    end
  end

  defp prepare do
    if Application.fetch_env!(:agent_link, :mode) == :connect do
      :ok
    else
      AgentLink.Setup.prepare()
    end
  end

  defp children do
    case Application.fetch_env!(:agent_link, :mode) do
      :plane -> {:ok, [AgentLink.Plane.Supervisor]}
      :relay -> {:ok, [AgentLink.Agent.Reaper, AgentLink.Relay.Agent]}
      :all -> {:ok, [AgentLink.Plane.Supervisor, AgentLink.Relay.Agent.Supervisor]}
      :connect -> connect_children()
    end
  end

  defp connect_children do
    root = Application.get_env(:agent_link, :config_root, AgentLink.Paths.root())

    case AgentLink.Config.load(
           plane: Application.get_env(:agent_link, :connect_plane),
           target: Application.get_env(:agent_link, :connect_target),
           token: Application.get_env(:agent_link, :connect_token),
           root: root,
           env: Application.get_env(:agent_link, :config_env, System.get_env())
         ) do
      {:ok, config} ->
        case require_connect(config, root) do
          :ok -> {:ok, [client_child(config, connect_watcher())]}
          {:error, message} -> reject_connect(message)
        end

      {:error, message} ->
        reject_connect(message)
    end
  end

  defp require_connect(%AgentLink.Config{plane: plane, token: token}, root) do
    cond do
      not is_binary(plane) -> {:error, missing_plane(root)}
      not is_binary(token) -> {:error, missing_token(root)}
      true -> :ok
    end
  end

  defp missing_plane(root) do
    "agentlink connect needs a plane URL. Pass --plane, set AGENTLINK_PLANE, or set plane in #{config_path(root)}.\n"
  end

  defp missing_token(root) do
    "agentlink connect needs a token. Pass --token, set AGENTLINK_TOKEN, or write #{token_path(root)}.\n"
  end

  defp config_path(root), do: Path.join(root, Path.basename(AgentLink.Paths.config()))
  defp token_path(root), do: Path.join(root, Path.basename(AgentLink.Paths.token()))

  defp reject_connect(message) do
    IO.puts(:stderr, message)
    boot_error(message)
  end

  defp client_child(%AgentLink.Config{} = config, watcher) do
    opts =
      [plane: config.plane, token: config.token, target: config.target]
      |> put_env_opt(:connect_transport, :transport)
      |> put_env_opt(:connect_stdio, :stdio)

    opts
    |> AgentLink.Relay.Client.child_spec()
    |> Map.put(:start, {__MODULE__, :start_client, [opts, watcher]})
    |> Map.put(:modules, [AgentLink.Relay.Client])
  end

  # The supervisor calls this. boot_client/2 runs in the client relay.
  @doc false
  def start_client(opts, watcher) when is_list(opts) and is_pid(watcher) do
    :proc_lib.start_link(__MODULE__, :boot_client, [opts, watcher])
  end

  # Monitor before the client relay handles stdin. A monitor taken after that
  # process has stopped reports :noproc and drops {:shutdown, "stdio closed"}.
  @doc false
  def boot_client(opts, watcher) when is_list(opts) and is_pid(watcher) do
    case AgentLink.Relay.Client.init(opts) do
      {:ok, state} ->
        monitor_client(watcher)
        :proc_lib.init_ack({:ok, self()})
        :gen_server.enter_loop(AgentLink.Relay.Client, [], state)

      {:stop, reason} ->
        exit(reason)
    end
  end

  defp put_env_opt(opts, env_key, opt_key) do
    case Application.get_env(:agent_link, env_key) do
      nil -> opts
      value -> Keyword.put(opts, opt_key, value)
    end
  end

  defp start_supervisor(children) do
    notify? = Application.fetch_env!(:agent_link, :mode) == :connect
    # The application starter already traps exits. A test calls start/2 from a
    # process that does not. Trap for the start_link so a child that stops in
    # init returns {:error, reason} to this process, which stays the parent.
    trapped? = Process.flag(:trap_exit, true)

    result =
      try do
        Supervisor.start_link(children, supervisor_opts())
      after
        if not trapped?, do: Process.flag(:trap_exit, false)
      end

    case result do
      {:ok, sup} = ok ->
        if notify?, do: notify_connect_watcher({:supervisor, sup})
        ok

      {:error, _reason} = error ->
        if notify?, do: stop_connect_watcher()
        flush_exits()
        error
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp supervisor_opts do
    [
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 20,
      name: AgentLink.Supervisor
    ]
  end

  defp watch_connect({:ok, _sup} = ok), do: ok

  defp watch_connect({:error, reason} = error) do
    case Application.fetch_env!(:agent_link, :mode) do
      :connect ->
        report_boot(start_failure(reason))

      mode when mode in [:relay, :all] ->
        case shutdown_message(reason) do
          message when is_binary(message) -> report_boot(message)
          _ -> error
        end

      _ ->
        error
    end
  end

  defp start_failure(reason) do
    case shutdown_message(reason) do
      message when is_binary(message) -> message
      _ -> "agentlink connect failed: #{inspect(reason)}\n"
    end
  end

  defp shutdown_message({:shutdown, reason}), do: shutdown_message(reason)
  defp shutdown_message({:failed_to_start_child, _id, reason}), do: shutdown_message(reason)
  defp shutdown_message(message) when is_binary(message), do: message
  defp shutdown_message(_reason), do: nil

  defp report_boot(message) do
    IO.puts(:stderr, message)
    boot_error(message)
  end

  defp connect_watcher do
    listener = Application.get_env(:agent_link, :halt_listener)
    watcher = spawn_link(fn -> connect_watch(listener) end)
    Application.put_env(:agent_link, :connect_watcher, watcher)
    watcher
  end

  defp stop_connect_watcher do
    case Application.get_env(:agent_link, :connect_watcher) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        send(pid, :stop)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp notify_connect_watcher(message) do
    case Application.get_env(:agent_link, :connect_watcher) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp monitor_client(watcher) do
    token = make_ref()
    ref = Process.monitor(watcher)
    send(watcher, {:connect_client, self(), token})

    receive do
      {:watching, ^token} ->
        Process.demonitor(ref, [:flush])

      {:DOWN, ^ref, :process, ^watcher, _reason} ->
        :ok
    end
  end

  defp connect_watch(listener) do
    watch_connect_client(listener, nil, nil)
  end

  defp watch_connect_client(listener, sup_ref, client_ref) do
    receive do
      {:connect_client, client, token} ->
        drop_monitor(client_ref)
        ref = Process.monitor(client)
        send(client, {:watching, token})
        if is_pid(listener), do: send(listener, {:connect_watching, self()})
        watch_connect_client(listener, sup_ref, ref)

      {:supervisor, sup} ->
        drop_monitor(sup_ref)
        ref = Process.monitor(sup)
        if is_pid(listener), do: send(listener, {:connect_supervisor, sup})
        watch_connect_client(listener, ref, client_ref)

      :stop ->
        :ok

      {:DOWN, ref, :process, _pid, reason}
      when is_reference(client_ref) and ref == client_ref ->
        case exit_code(reason) do
          nil -> watch_connect_client(listener, sup_ref, nil)
          code -> connect_exit(listener, code)
        end

      {:DOWN, ref, :process, _pid, _reason} when is_reference(sup_ref) and ref == sup_ref ->
        connect_exit(listener, 1)
    end
  end

  defp drop_monitor(nil), do: :ok
  defp drop_monitor(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])

  defp exit_code({:shutdown, "stdio closed"}), do: 0
  defp exit_code({:shutdown, message}) when is_binary(message), do: 1
  defp exit_code(_reason), do: nil

  if @halt_boot_error do
    defp install_connect_stop do
      if Application.get_env(:agent_link, :mode) == :connect do
        case :gen_event.swap_handler(
               :erl_signal_server,
               {:erl_signal_handler, []},
               {AgentLink.ConnectStop, []}
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            boot_error(
              "agentlink connect could not install the SIGTERM handler: #{inspect(reason)}\n"
            )
        end
      else
        :ok
      end
    end

    defp connect_exit(_listener, code) when code in [0, 1] do
      if match?({:stopping, _}, :init.get_status()) do
        :ok
      else
        Logger.flush()
        System.halt(code)
      end
    end
  else
    defp install_connect_stop, do: :ok

    defp connect_exit(listener, code) when code in [0, 1] do
      if is_pid(listener), do: send(listener, {:connect_exit, code})
      :ok
    end
  end

  defp boot_error(message) do
    if @halt_boot_error, do: System.halt(1), else: {:error, message}
  end
end
