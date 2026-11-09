defmodule AgentLink.LifecycleTest do
  @moduledoc """
  The supervision tree each mode starts, and the stop that follows.

  The test process calls `AgentLink.Application.start/2`, so it is
  `AgentLink.Supervisor`'s parent. `Process.exit/2` with `:shutdown` is the
  same signal `application_master` sends. Assertions run before `on_exit`.
  The hold fixture ignores `SIGTERM` and stdin EOF. `:agent_stop_timeout`
  is `0` in that test, so `close/1` signals `SIGKILL` without waiting out
  the default `5000`, then waits until the recorded processes are gone.
  The replacement test checks those processes before it looks up the new
  relay. `await_accept!/1` gives up after `5000` milliseconds.
  """

  use ExUnit.Case, async: false

  setup do
    Process.flag(:trap_exit, true)

    previous = %{
      mode: Application.get_env(:agent_link, :mode),
      port: Application.get_env(:agent_link, :port),
      link_path: Application.get_env(:agent_link, :link_path),
      agent_module: Application.get_env(:agent_link, :agent_module),
      agent_stop_timeout: Application.get_env(:agent_link, :agent_stop_timeout),
      connect_plane: Application.get_env(:agent_link, :connect_plane),
      connect_target: Application.get_env(:agent_link, :connect_target),
      connect_token: Application.get_env(:agent_link, :connect_token),
      connect_transport: Application.get_env(:agent_link, :connect_transport),
      connect_stdio: Application.get_env(:agent_link, :connect_stdio),
      connect_observer: Application.get_env(:agent_link, :connect_observer),
      config_root: Application.get_env(:agent_link, :config_root),
      halt_listener: Application.get_env(:agent_link, :halt_listener)
    }

    on_exit(fn ->
      # A timed-out test is already a failure. Kill the names it registered
      # so the next test is not an :already_started cascade.
      for name <- [
            AgentLink.Supervisor,
            AgentLink.Relay.Agent.Supervisor,
            AgentLink.Plane.Supervisor,
            AgentLink.Relay.Agent
          ] do
        if pid = Process.whereis(name) do
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            1_000 -> :ok
          end
        end
      end

      Enum.each(previous, fn {key, value} -> AgentLink.TestHelpers.restore(key, value) end)
    end)

    :ok
  end

  test "plane mode is parented by the caller and stop closes the listener" do
    port = 18_421
    missing = missing_link()
    sup = start!(:plane, port: port)
    assert Process.info(sup, :parent) == {:parent, self()}
    assert linked_to_self?(sup)
    assert child_ids(sup) == %{AgentLink.Plane.Supervisor => :supervisor}
    plane = Process.whereis(AgentLink.Plane.Supervisor)

    assert child_ids(plane) == %{
             AgentLink.Registry => :worker,
             AgentLink.Plane.Sessions => :worker,
             AgentLink.Plane => :worker,
             AgentLink.Setup.Watch => :worker,
             Bandit => :supervisor
           }

    refute Process.whereis(AgentLink.Relay.Agent)
    refute File.exists?(missing)
    await_accept!(port)
    stop!(sup)
    await_closed!(port)
  end

  test "stopping the plane supervisor restarts the listener, and stopping the top supervisor closes it" do
    port = 18_422
    sup = start!(:plane, port: port)
    plane = Process.whereis(AgentLink.Plane.Supervisor)
    bandit = child_pid(plane, Bandit)
    ref = Process.monitor(bandit)
    assert :ok = Supervisor.stop(plane)
    assert_receive {:DOWN, ^ref, :process, ^bandit, _reason}
    new_plane = await_named(AgentLink.Plane.Supervisor, plane)
    new_bandit = child_pid(new_plane, Bandit)
    assert new_bandit != bandit
    await_accept!(port)
    stop!(sup)
    await_closed!(port)
    refute Process.whereis(AgentLink.Plane.Supervisor)
  end

  test "relay mode starts only the agent relay and stop removes it" do
    write_link!()
    sup = start!(:relay)
    assert Process.info(sup, :parent) == {:parent, self()}
    assert linked_to_self?(sup)
    assert child_ids(sup) == %{AgentLink.Relay.Agent => :worker}
    refute Process.whereis(AgentLink.Plane.Supervisor)
    refute accept?(18_421)
    stop!(sup)
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "all mode starts the plane and the relay supervisor, and stop closes the listener" do
    port = 18_423
    write_link!()
    sup = start!(:all, port: port)
    assert Process.info(sup, :parent) == {:parent, self()}
    assert linked_to_self?(sup)

    assert child_ids(sup) == %{
             AgentLink.Plane.Supervisor => :supervisor,
             AgentLink.Relay.Agent.Supervisor => :supervisor
           }

    relay = Process.whereis(AgentLink.Relay.Agent.Supervisor)
    assert child_ids(relay) == %{AgentLink.Relay.Agent => :worker}
    await_accept!(port)
    stop!(sup)
    await_closed!(port)
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "connect mode starts only the client relay, and the watcher is linked to the caller" do
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect!()
    sup = start!(:connect)
    assert_receive {:connect_supervisor, ^sup}
    assert Process.info(sup, :parent) == {:parent, self()}
    assert linked_to_self?(sup)
    assert child_ids(sup) == %{AgentLink.Relay.Client => :worker}
    watcher = Application.get_env(:agent_link, :connect_watcher)
    assert is_pid(watcher)
    assert linked_to_self?(watcher)
    refute Process.whereis(AgentLink.Plane.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
    stop!(sup)
    assert_receive {:connect_exit, 1}
    refute_received {:connect_exit, 0}
  end

  test "a relay restart and a later stop reap the agent process group" do
    Application.put_env(:agent_link, :agent_module, AgentLink.Agent.Process)
    Application.put_env(:agent_link, :agent_stop_timeout, 0)
    pidfile = hold_link!()
    sup = start!(:relay)
    agent = Process.whereis(AgentLink.Relay.Agent)
    ref = Process.monitor(agent)
    {parent, child} = await_hold!(pidfile, agent)
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    File.rm!(pidfile)
    assert :ok = GenServer.stop(agent, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^agent, _reason}
    await_gone!(parent, parent_started)
    await_gone!(child, child_started)
    new_agent = await_named(AgentLink.Relay.Agent, agent)
    {parent2, child2} = await_hold!(pidfile, new_agent)
    assert parent2 != parent
    assert child2 != child
    parent2_started = starttime!(parent2)
    child2_started = starttime!(child2)
    stop!(sup)
    await_gone!(parent2, parent2_started)
    await_gone!(child2, child2_started)
  end

  test "the replacement agent does not start while the old one is still alive" do
    Application.put_env(:agent_link, :agent_module, AgentLink.Agent.Process)
    Application.put_env(:agent_link, :agent_stop_timeout, 0)
    pidfile = hold_link!()
    sup = start!(:relay)
    agent = Process.whereis(AgentLink.Relay.Agent)
    {parent, child} = await_hold!(pidfile, agent)
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    File.rm!(pidfile)

    test_pid = self()

    watcher =
      spawn(fn ->
        watch_replacement(test_pid, agent, parent, parent_started, child, child_started)
      end)

    assert :ok = GenServer.stop(agent, :shutdown)
    refute os_alive?(parent, parent_started)
    refute os_alive?(child, child_started)
    send(watcher, :stop)
    assert_receive {:overlap, :clear}
    new_agent = await_named(AgentLink.Relay.Agent, agent)
    {parent2, child2} = await_hold!(pidfile, new_agent)
    assert parent2 != parent
    assert child2 != child
    parent2_started = starttime!(parent2)
    child2_started = starttime!(child2)
    stop!(sup)
    await_gone!(parent2, parent2_started)
    await_gone!(child2, child2_started)
  end

  test "all mode stop reaps the agent process group and closes the listener" do
    port = 18_424
    Application.put_env(:agent_link, :agent_module, AgentLink.Agent.Process)
    Application.put_env(:agent_link, :agent_stop_timeout, 0)
    pidfile = hold_link!()
    sup = start!(:all, port: port)
    await_accept!(port)
    agent = Process.whereis(AgentLink.Relay.Agent)
    {parent, child} = await_hold!(pidfile, agent)
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    stop!(sup)
    await_closed!(port)
    await_gone!(parent, parent_started)
    await_gone!(child, child_started)
  end

  defp start!(mode, opts \\ []) do
    Application.put_env(:agent_link, :mode, mode)
    if port = opts[:port], do: Application.put_env(:agent_link, :port, port)
    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    sup
  end

  defp stop!(sup) do
    ref = Process.monitor(sup)
    Process.exit(sup, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}
  end

  defp child_ids(sup) do
    Map.new(Supervisor.which_children(sup), fn {id, pid, type, _modules} ->
      assert is_pid(pid)
      {child_name(id), type}
    end)
  end

  defp child_pid(sup, id) do
    {_id, pid, _type, _modules} =
      Enum.find(Supervisor.which_children(sup), fn {child_id, _, _, _} ->
        child_name(child_id) == id
      end)

    pid
  end

  defp child_name({Bandit, _ref}), do: Bandit
  defp child_name(id), do: id

  defp linked_to_self?(pid) do
    {:links, links} = Process.info(pid, :links)
    self() in links
  end

  defp missing_link do
    path =
      Path.join(System.tmp_dir!(), "agentlink-missing-#{System.unique_integer([:positive])}.json")

    Application.put_env(:agent_link, :link_path, path)
    path
  end

  defp write_link! do
    path =
      Path.join(System.tmp_dir!(), "agentlink-life-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:9/agent","command":"agentlink-fake","args":["acp"]})
    )

    Application.put_env(:agent_link, :link_path, path)
    path
  end

  defp hold_link! do
    dir = Path.join(System.tmp_dir!(), "agentlink-hold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    pidfile = Path.join(dir, "pids")
    script = Path.expand("fixtures/agentlink_hold_fixture.py", __DIR__)
    File.chmod!(script, 0o755)
    python = System.find_executable("python3")
    assert is_binary(python)

    body =
      Jason.encode!(%{
        "name" => "fixture",
        "label" => "lifecycle",
        "program" => "fixture",
        "plane_url" => "ws://127.0.0.1:9/agent",
        "command" => python,
        "args" => [script, pidfile, "quiet"]
      })

    path = Path.join(dir, "agent.link.json")
    File.write!(path, body)
    Application.put_env(:agent_link, :link_path, path)
    pidfile
  end

  defp put_connect! do
    root = Path.join(System.tmp_dir!(), "agentlink-connect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Application.put_env(:agent_link, :config_root, root)
    Application.put_env(:agent_link, :connect_plane, "ws://127.0.0.1:9/acp")
    Application.put_env(:agent_link, :connect_target, "lab")
    Application.put_env(:agent_link, :connect_token, "sekret")

    Application.put_env(:agent_link, :connect_transport, AgentLink.FakeTransport)
    Application.put_env(:agent_link, :connect_stdio, AgentLink.FakeStdio)
    Application.put_env(:agent_link, :connect_observer, self())
    missing_link()
  end

  @accept_deadline_ms 5_000

  defp await_accept!(port) do
    await_accept!(port, System.monotonic_time(:millisecond))
  end

  defp await_accept!(port, started) do
    cond do
      accept?(port) ->
        :ok

      System.monotonic_time(:millisecond) - started >= @accept_deadline_ms ->
        flunk("127.0.0.1:#{port} did not accept within #{@accept_deadline_ms}ms")

      true ->
        receive do
        after
          0 -> await_accept!(port, started)
        end
    end
  end

  defp accept?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp await_closed!(port) do
    if accept?(port) do
      receive do
      after
        0 -> await_closed!(port)
      end
    else
      :ok
    end
  end

  defp await_named(name, previous) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ ->
        receive do
        after
          0 -> await_named(name, previous)
        end
    end
  end

  defp await_hold!(pidfile, agent) do
    receive do
      {:DOWN, _ref, :process, ^agent, reason} ->
        flunk("agent relay exited before the hold fixture reported: #{inspect(reason)}")
    after
      0 ->
        case File.read(pidfile) do
          {:ok, line} ->
            case Regex.run(~r/ready (\d+) (\d+)/, line) do
              [_, parent, child] ->
                {String.to_integer(parent), String.to_integer(child)}

              _ ->
                await_hold!(pidfile, agent)
            end

          _ ->
            await_hold!(pidfile, agent)
        end
    end
  end

  defp starttime!(pid) do
    {:ok, stat} = File.read("/proc/#{pid}/stat")
    {:ok, %{starttime: starttime}} = AgentLink.OwnedStop.parse_stat(stat)
    starttime
  end

  defp watch_replacement(dest, old, parent, parent_started, child, child_started) do
    receive do
      :stop ->
        send(dest, {:overlap, :clear})
    after
      0 ->
        case Process.whereis(AgentLink.Relay.Agent) do
          pid when is_pid(pid) and pid != old ->
            outcome =
              if os_alive?(parent, parent_started) or os_alive?(child, child_started),
                do: :alive,
                else: :clear

            send(dest, {:overlap, outcome})

          _ ->
            watch_replacement(dest, old, parent, parent_started, child, child_started)
        end
    end
  end

  defp os_alive?(pid, starttime) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case AgentLink.OwnedStop.parse_stat(stat) do
          {:ok, %{starttime: ^starttime}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp await_gone!(pid, starttime) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case AgentLink.OwnedStop.parse_stat(stat) do
          {:ok, %{starttime: ^starttime}} ->
            receive do
            after
              0 -> await_gone!(pid, starttime)
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
