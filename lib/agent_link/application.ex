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
  the command exits with status 0. Any other `{:shutdown, message}` exits
  with status 1. A crash starts the client relay again. The supervisor's own
  stop exits with status 1. In the test environment, `:halt_listener` receives
  `{:connect_watching, pid}` after the watcher monitors the client relay, and
  `{:connect_exit, code}` instead of halting.
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
          :ok -> {:ok, [client_child(config)]}
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

  defp client_child(%AgentLink.Config{} = config) do
    opts =
      [plane: config.plane, token: config.token, target: config.target]
      |> put_env_opt(:connect_transport, :transport)
      |> put_env_opt(:connect_stdio, :stdio)

    AgentLink.Relay.Client.child_spec(opts)
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
              ok

            other ->
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

  defp watch_connect({:ok, sup} = ok) do
    if Application.fetch_env!(:agent_link, :mode) == :connect do
      listener = Application.get_env(:agent_link, :halt_listener)
      spawn(fn -> monitor_connect(sup, listener) end)
    end

    ok
  end

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

  defp monitor_connect(sup, listener) do
    sup_ref = Process.monitor(sup)
    follow_client(sup, sup_ref, listener)
  end

  defp follow_client(sup, sup_ref, listener) do
    case connect_client(sup) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        if is_pid(listener), do: send(listener, {:connect_watching, self()})

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case exit_code(reason) do
              nil -> follow_client(sup, sup_ref, listener)
              code -> connect_exit(listener, code)
            end

          {:DOWN, ^sup_ref, :process, ^sup, _reason} ->
            connect_exit(listener, 1)
        end

      _other ->
        connect_exit(listener, 1)
    end
  end

  # which_children is a call, so it runs after the EXIT that killed the
  # previous client. A restart has finished, or the child is :undefined.
  defp connect_client(sup) do
    case which_client(sup) do
      :restarting -> which_client(sup)
      other -> other
    end
  end

  defp which_client(sup) do
    try do
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {AgentLink.Relay.Client, pid, _type, _mods} when is_pid(pid) -> pid
        {AgentLink.Relay.Client, :restarting, _type, _mods} -> :restarting
        _child -> nil
      end)
    catch
      :exit, _ -> nil
    end
  end

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
