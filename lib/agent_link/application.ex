defmodule AgentLink.Application do
  @moduledoc """
  `agentlink` runs the plane and the relay in one BEAM. `agentlink plane` and
  `agentlink relay` split them onto two machines. They still talk over the agent
  WebSocket. The link file holds the name, the label, the program, and the plane URL.

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
  handles stdin. Any other `{:shutdown, message}` exits with status 1. The
  supervisor starts the client relay again after a crash because
  `AgentLink.Relay.Client.child_spec/1` sets `restart: :transient`. The
  supervisor's own stop exits with status 1. In the test environment,
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
         :ok <- ensure_link(),
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

  defp ensure_link do
    case Application.fetch_env!(:agent_link, :mode) do
      mode when mode in [:plane, :connect] ->
        :ok

      _ ->
        case AgentLink.Link.read() do
          {:ok, _link} ->
            :ok

          {:error, message} ->
            IO.puts(:stderr, message)
            boot_error(message)
        end
    end
  end

  defp children do
    case Application.fetch_env!(:agent_link, :mode) do
      :plane -> {:ok, [AgentLink.Plane.Supervisor]}
      :relay -> {:ok, [AgentLink.Relay.Agent]}
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

      other ->
        exit({:bad_return_value, other})
    end
  end

  defp put_env_opt(opts, env_key, opt_key) do
    case Application.get_env(:agent_link, env_key) do
      nil -> opts
      value -> Keyword.put(opts, opt_key, value)
    end
  end

  defp start_supervisor(children) do
    if Application.fetch_env!(:agent_link, :mode) == :connect do
      start_connect_supervisor(children)
    else
      Supervisor.start_link(children, supervisor_opts())
    end
  end

  # A child that stops in init kills a linked caller that does not trap exits,
  # so start_link never gets to return the error. Start in a process that
  # traps exits, then unlink a live supervisor. The application master links
  # the pid this function returns.
  defp start_connect_supervisor(children) do
    parent = self()
    ref = make_ref()

    starter =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result =
          case Supervisor.start_link(children, supervisor_opts()) do
            {:ok, sup} = ok ->
              Process.unlink(sup)
              notify_connect_watcher({:supervisor, sup})
              ok

            other ->
              notify_connect_watcher(:stop)
              other
          end

        send(parent, {ref, result})
      end)

    starter_ref = Process.monitor(starter)

    receive do
      {^ref, result} ->
        Process.demonitor(starter_ref, [:flush])
        result

      {:DOWN, ^starter_ref, :process, ^starter, reason} ->
        {:error, reason}
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
    if Application.fetch_env!(:agent_link, :mode) == :connect do
      message = start_failure(reason)
      IO.puts(:stderr, message)
      boot_error(message)
    else
      error
    end
  end

  defp watch_connect(other), do: other

  defp start_failure({:shutdown, reason}), do: start_failure(reason)
  defp start_failure({:failed_to_start_child, _id, reason}), do: start_failure(reason)
  defp start_failure(message) when is_binary(message), do: message
  defp start_failure(reason), do: "agentlink connect failed: #{inspect(reason)}\n"

  defp connect_watcher do
    listener = Application.get_env(:agent_link, :halt_listener)
    watcher = spawn(fn -> connect_watch(listener) end)
    Application.put_env(:agent_link, :connect_watcher, watcher)
    watcher
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

  defp connect_exit(listener, code) when code in [0, 1] do
    if @halt_boot_error do
      System.halt(code)
    else
      if is_pid(listener), do: send(listener, {:connect_exit, code})
      :ok
    end
  end

  defp boot_error(message) do
    if @halt_boot_error, do: System.halt(1), else: {:error, message}
  end
end
