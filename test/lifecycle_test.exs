defmodule AgentLink.LifecycleTest do
  @moduledoc """
  The supervision tree each mode starts, and the stop that follows.

  The test process calls `AgentLink.Application.start/2`, so it is
  `AgentLink.Supervisor`'s parent. `Process.exit/2` with `:shutdown` is the
  same signal `application_master` sends. Assertions run before `on_exit`.
  The hold fixture ignores `SIGTERM` and stdin EOF. `:agent_stop_timeout`
  is `0` in that test, so `close/1` signals `SIGKILL` without waiting out
  the default `5000`, then waits until the recorded processes are gone.
  The replacement test checks those start times when the new relay calls
  `open/5`. The sticky test keeps a process alive through `close/1` and
  hides `kill`, so the next start fails while that start time still matches.
  Listener checks wait for socket state, bounded by ExUnit's test timeout.
  """

  use ExUnit.Case, async: false

  setup do
    Process.flag(:trap_exit, true)

    previous = %{
      mode: Application.get_env(:agent_link, :mode),
      relay_token: Application.get_env(:agent_link, :relay_token),
      master_token: Application.get_env(:agent_link, :master_token),
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
      halt_listener: Application.get_env(:agent_link, :halt_listener),
      agent_open_listener: Application.get_env(:agent_link, :agent_open_listener),
      sticky_listener: Application.get_env(:agent_link, :sticky_listener),
      reaper_dir: Application.get_env(:agent_link, :reaper_dir)
    }

    reaper_dir =
      Path.join(System.tmp_dir!(), "agentlink-reaper-#{System.unique_integer([:positive])}")

    File.mkdir_p!(reaper_dir)
    Application.put_env(:agent_link, :reaper_dir, reaper_dir)

    on_exit(fn ->
      # A timed-out test is already a failure. Kill the names it registered
      # so the next test is not an :already_started cascade.
      for name <- [
            AgentLink.Supervisor,
            AgentLink.Relay.Agent.Supervisor,
            AgentLink.Plane.Supervisor,
            AgentLink.Agent.Reaper,
            AgentLink.Relay.Agent,
            AgentLink.Uplink
          ] do
        if pid = Process.whereis(name) do
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          AgentLink.TestHelpers.await_down(ref, pid)
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
    sup = start!(:plane, port: 0)
    plane = Process.whereis(AgentLink.Plane.Supervisor)
    bandit = child_pid(plane, Bandit)
    {:ok, {_, old_port}} = ThousandIsland.listener_info(bandit)
    ref = Process.monitor(bandit)
    assert :ok = Supervisor.stop(plane)
    AgentLink.TestHelpers.await_down(ref, bandit)
    new_plane = await_named(AgentLink.Plane.Supervisor, plane)
    new_bandit = child_pid(new_plane, Bandit)
    assert new_bandit != bandit
    {:ok, {_, port}} = ThousandIsland.listener_info(new_bandit)
    if old_port != port, do: await_closed!(old_port)
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

    assert child_ids(sup) == %{
             AgentLink.Agent.Reaper => :worker,
             AgentLink.Relay.Agent => :worker
           }

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

    assert child_ids(relay) == %{
             AgentLink.Agent.Reaper => :worker,
             AgentLink.Relay.Agent => :worker
           }

    await_accept!(port)
    stop!(sup)
    await_closed!(port)
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "connect mode starts only the client relay, and the watcher is linked to the caller" do
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect!()
    sup = start!(:connect)

    receive do
      {:connect_supervisor, ^sup} -> :ok
    end

    assert Process.info(sup, :parent) == {:parent, self()}
    assert linked_to_self?(sup)
    assert child_ids(sup) == %{AgentLink.Relay.Client => :worker}
    watcher = Application.get_env(:agent_link, :connect_watcher)
    assert is_pid(watcher)
    assert linked_to_self?(watcher)
    refute Process.whereis(AgentLink.Plane.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
    stop!(sup)

    code =
      receive do
        {:connect_exit, code} -> code
      end

    assert code == 1
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
    AgentLink.TestHelpers.await_down(ref, agent)
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
    Application.put_env(:agent_link, :agent_open_listener, self())
    pidfile = hold_link!()
    sup = start!(:relay)
    agent = Process.whereis(AgentLink.Relay.Agent)
    {parent, child} = await_hold!(pidfile, agent)
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    assert_received {:agent_opening, _owner}
    File.rm!(pidfile)
    assert :ok = GenServer.stop(agent, :shutdown)

    receive do
      {:agent_opening, _owner} -> :ok
    end

    refute os_alive?(parent, parent_started)
    refute os_alive?(child, child_started)
    refute File.exists?(pidfile)
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

  test "a process that survives close blocks the replacement" do
    Application.put_env(:agent_link, :agent_module, AgentLink.LifecycleTest.Sticky)
    Application.put_env(:agent_link, :agent_stop_timeout, 0)
    Application.put_env(:agent_link, :sticky_listener, self())
    pidfile = sticky_link!()
    sup = start!(:relay)
    assert_received {:sticky_opened, os_pid}
    started = starttime!(os_pid)
    kill = System.find_executable("kill")
    path = System.get_env("PATH")

    on_exit(fn ->
      if is_binary(path), do: System.put_env("PATH", path)

      if is_binary(kill) and os_alive?(os_pid, started) and
           Integer.to_string(os_pid) != System.pid() do
        System.cmd(kill, ["-s", "KILL", "--", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end)

    empty =
      Path.join(System.tmp_dir!(), "agentlink-no-kill-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty)
    System.put_env("PATH", empty)
    ref = Process.monitor(sup)
    assert :ok = GenServer.stop(Process.whereis(AgentLink.Relay.Agent), :shutdown)
    AgentLink.TestHelpers.await_down(ref, sup)
    refute Process.whereis(AgentLink.Relay.Agent)
    assert os_alive?(os_pid, started)
    refute_received {:sticky_opened, _}
    refute File.exists?(pidfile)
  end

  test "a reaper restart still blocks the next open" do
    Application.put_env(:agent_link, :agent_module, AgentLink.LifecycleTest.Sticky)
    Application.put_env(:agent_link, :sticky_listener, self())
    sticky_link!()
    assert {:ok, reaper} = AgentLink.Agent.Reaper.start_link()

    assert {:ok, _relay} =
             AgentLink.Relay.Agent.start_link(
               transport: AgentLink.FakeTransport,
               transport_opts: [backoff: 60_000],
               watch_interval: nil
             )

    os_pid = await_sticky_opened()
    started = starttime!(os_pid)
    record = AgentLink.Agent.Reaper.record_path()
    kill = System.find_executable("kill")
    path = System.get_env("PATH")

    on_exit(fn ->
      if is_binary(path), do: System.put_env("PATH", path)
      stop_named(AgentLink.Relay.Agent)
      stop_named(AgentLink.Uplink)
      stop_named(AgentLink.Agent.Reaper)

      if is_binary(kill) and os_alive?(os_pid, started) and
           Integer.to_string(os_pid) != System.pid() do
        System.cmd(kill, ["-s", "KILL", "--", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end)

    assert :ok = GenServer.stop(AgentLink.Relay.Agent, :shutdown)
    stop_named(AgentLink.Uplink)
    ref = Process.monitor(reaper)
    Process.exit(reaper, :kill)
    assert AgentLink.TestHelpers.await_down(ref, reaper) == :killed
    assert File.regular?(record)
    refute Process.whereis(AgentLink.Agent.Reaper)
    assert {:ok, _reaper} = AgentLink.Agent.Reaper.start_link()

    empty =
      Path.join(System.tmp_dir!(), "agentlink-no-kill-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty)
    System.put_env("PATH", empty)

    assert {:error, {:reap, :no_kill}} =
             AgentLink.Relay.Agent.start_link(
               transport: AgentLink.FakeTransport,
               transport_opts: [backoff: 60_000],
               watch_interval: nil
             )

    refute_received {:sticky_opened, _}
    assert os_alive?(os_pid, started)
    assert AgentLink.Agent.Process.same_start?(os_pid, field_starttime!(os_pid))
  end

  test "reap and retain fail when the reaper is absent" do
    refute Process.whereis(AgentLink.Agent.Reaper)
    assert AgentLink.Agent.Reaper.reap() == {:error, :noproc}
    assert AgentLink.Agent.Reaper.retain([]) == {:error, :noproc}
  end

  test "init drops a record whose start time does not match" do
    Application.put_env(:agent_link, :agent_module, AgentLink.LifecycleTest.Sticky)
    Application.put_env(:agent_link, :sticky_listener, self())
    sticky_link!()
    assert {:ok, reaper} = AgentLink.Agent.Reaper.start_link()

    assert {:ok, _relay} =
             AgentLink.Relay.Agent.start_link(
               transport: AgentLink.FakeTransport,
               transport_opts: [backoff: 60_000],
               watch_interval: nil
             )

    os_pid = await_sticky_opened()
    started = starttime!(os_pid)
    kill = System.find_executable("kill")

    on_exit(fn ->
      stop_named(AgentLink.Relay.Agent)
      stop_named(AgentLink.Uplink)
      stop_named(AgentLink.Agent.Reaper)

      if is_binary(kill) and os_alive?(os_pid, started) and
           Integer.to_string(os_pid) != System.pid() do
        System.cmd(kill, ["-s", "KILL", "--", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end)

    assert :ok = GenServer.stop(AgentLink.Relay.Agent, :shutdown)
    stop_named(AgentLink.Uplink)
    stop_named(reaper)
    AgentLink.Agent.Reaper.install_pairs([{os_pid, "not-the-start-time"}])
    assert {:ok, _} = AgentLink.Agent.Reaper.start_link()
    assert :ok = AgentLink.Agent.Reaper.reap()
    assert os_alive?(os_pid, started)
  end

  test "a close while the reaper is down still blocks the next open" do
    Application.put_env(:agent_link, :agent_module, AgentLink.LifecycleTest.Sticky)
    Application.put_env(:agent_link, :sticky_listener, self())
    sticky_link!()
    assert {:ok, reaper} = AgentLink.Agent.Reaper.start_link()

    assert {:ok, _relay} =
             AgentLink.Relay.Agent.start_link(
               transport: AgentLink.FakeTransport,
               transport_opts: [backoff: 60_000],
               watch_interval: nil
             )

    os_pid = await_sticky_opened()
    started = starttime!(os_pid)
    kill = System.find_executable("kill")
    path = System.get_env("PATH")

    on_exit(fn ->
      if is_binary(path), do: System.put_env("PATH", path)
      stop_named(AgentLink.Relay.Agent)
      stop_named(AgentLink.Uplink)
      stop_named(AgentLink.Agent.Reaper)

      if is_binary(kill) and os_alive?(os_pid, started) and
           Integer.to_string(os_pid) != System.pid() do
        System.cmd(kill, ["-s", "KILL", "--", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end)

    ref = Process.monitor(reaper)
    Process.exit(reaper, :kill)
    assert AgentLink.TestHelpers.await_down(ref, reaper) == :killed
    assert :ok = GenServer.stop(AgentLink.Relay.Agent, :shutdown)
    stop_named(AgentLink.Uplink)
    assert {os_pid, field_starttime!(os_pid)} in AgentLink.Agent.Reaper.read_pairs()
    assert {:ok, _reaper} = AgentLink.Agent.Reaper.start_link()

    empty =
      Path.join(System.tmp_dir!(), "agentlink-no-kill-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty)
    System.put_env("PATH", empty)

    assert {:error, {:reap, :no_kill}} =
             AgentLink.Relay.Agent.start_link(
               transport: AgentLink.FakeTransport,
               transport_opts: [backoff: 60_000],
               watch_interval: nil
             )

    refute_received {:sticky_opened, _}
    assert os_alive?(os_pid, started)
  end

  test "a supervised stop removes this VM's reaper file" do
    assert {:ok, sup} = Supervisor.start_link([AgentLink.Agent.Reaper], strategy: :one_for_one)
    path = AgentLink.Agent.Reaper.record_path()
    assert File.regular?(path)
    assert :ok = Supervisor.stop(sup, :shutdown)
    refute File.regular?(path)
  end

  test "two reapers in one directory keep separate records" do
    python = System.find_executable("python3")

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:args, ["-c", pause_script()]}
      ])

    {:os_pid, other} = Port.info(port, :os_pid)
    other_started = starttime!(other)
    other_field = AgentLink.Agent.Process.starttime(other)
    vm = AgentLink.Agent.Reaper.vm_owner()
    kill = System.find_executable("kill")

    on_exit(fn ->
      if is_binary(kill) and os_alive?(other, other_started) and
           Integer.to_string(other) != System.pid() do
        System.cmd(kill, ["-s", "KILL", "--", Integer.to_string(other)], stderr_to_stdout: true)
      end
    end)

    assert {:ok, left} = AgentLink.Agent.Reaper.start_link(name: false, vm: vm)

    assert {:ok, right} =
             AgentLink.Agent.Reaper.start_link(name: false, vm: {other, other_field})

    on_exit(fn ->
      for pid <- [left, right] do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    assert :ok = GenServer.call(left, {:retain, [{other, other_field}]})
    {vm_pid, vm_field} = vm
    assert :ok = GenServer.call(right, {:retain, [{vm_pid, vm_field}]})

    left_path = AgentLink.Agent.Reaper.record_path(vm)
    right_path = AgentLink.Agent.Reaper.record_path({other, other_field})
    assert left_path != right_path
    assert rem(File.stat!(left_path).mode, 0o1000) == 0o600
    assert rem(File.stat!(right_path).mode, 0o1000) == 0o600
    left_bytes = File.read!(left_path)
    right_bytes = File.read!(right_path)
    assert {other, other_field} in pairs(left_bytes)
    assert {vm_pid, vm_field} in pairs(right_bytes)
    refute {other, other_field} in pairs(right_bytes)

    dead = Path.join(Path.dirname(left_path), "agent-reaper-2000000000-1.bin")
    File.write!(dead, left_bytes)
    assert :ok = GenServer.stop(left)
    refute File.regular?(left_path)
    assert File.read!(right_path) == right_bytes
    assert {:ok, again} = AgentLink.Agent.Reaper.start_link(name: false, vm: vm)
    refute File.regular?(dead)
    assert File.read!(right_path) == right_bytes
    assert :ok = GenServer.stop(again)
    assert :ok = GenServer.stop(right)
    refute File.regular?(right_path)
    Port.close(port)
  end

  test "a sweep without a start time leaves other files and drops this VM's extras" do
    vm = AgentLink.Agent.Reaper.vm_owner()
    {pid, start} = vm
    dir = Application.fetch_env!(:agent_link, :reaper_dir)
    payload = :erlang.term_to_binary({:agentlink_reaper, 1, []})

    other_bin = Path.join(dir, "agent-reaper-2000000001-4242.bin")
    other_bad = other_bin <> ".bad-1"
    other_tmp = Path.join(dir, "agent-reaper-2000000001-4242-9.tmp")
    zero_bin = Path.join(dir, "agent-reaper-2000000002-0.bin")
    own_bad = Path.join(dir, "agent-reaper-#{pid}-#{start}.bin.bad-4")
    own_tmp = Path.join(dir, "agent-reaper-#{pid}-#{start}-8.tmp")

    for path <- [other_bin, other_bad, other_tmp, zero_bin, own_bad, own_tmp] do
      File.write!(path, payload)
    end

    assert {:ok, reaper} =
             AgentLink.Agent.Reaper.start_link(
               name: false,
               vm: vm,
               starttime: fn _pid ->
                 :unknown
               end
             )

    on_exit(fn ->
      if Process.alive?(reaper), do: Process.exit(reaper, :kill)
    end)

    assert File.regular?(other_bin)
    assert File.regular?(other_bad)
    assert File.regular?(other_tmp)
    assert File.regular?(zero_bin)
    refute File.regular?(own_bad)
    refute File.regular?(own_tmp)
    assert File.regular?(AgentLink.Agent.Reaper.record_path(vm))
  end

  test "a sweep leaves a stored start time of 0 and drops a confirmed dead owner" do
    vm = AgentLink.Agent.Reaper.vm_owner()
    dir = Application.fetch_env!(:agent_link, :reaper_dir)
    payload = :erlang.term_to_binary({:agentlink_reaper, 1, []})
    live = System.pid() |> String.to_integer()
    live_zero = Path.join(dir, "agent-reaper-#{live}-0.bin")
    dead_real = Path.join(dir, "agent-reaper-2000000004-99.bin")
    same_start = Path.join(dir, "agent-reaper-2000000005-999.bin")
    other_start = Path.join(dir, "agent-reaper-2000000006-111.bin")

    for path <- [live_zero, dead_real, same_start, other_start] do
      File.write!(path, payload)
    end

    reader = fn
      2_000_000_004 -> :gone
      _pid -> {:ok, "999"}
    end

    assert {:ok, reaper} =
             AgentLink.Agent.Reaper.start_link(name: false, vm: vm, starttime: reader)

    on_exit(fn ->
      if Process.alive?(reaper), do: Process.exit(reaper, :kill)
    end)

    assert File.regular?(live_zero)
    assert File.regular?(same_start)
    refute File.regular?(dead_real)
    refute File.regular?(other_start)
  end

  test "an absent retain during init still blocks the next open" do
    python = System.find_executable("python3")

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:args, ["-c", pause_script()]}
      ])

    {:os_pid, other} = Port.info(port, :os_pid)
    other_started = starttime!(other)
    other_field = AgentLink.Agent.Process.starttime(other)
    kill = System.find_executable("kill")
    path = System.get_env("PATH")
    parent = self()

    Application.put_env(:agent_link, :reaper_after_load, fn ->
      send(parent, {:between, self()})

      receive do
        :resume -> :ok
      end
    end)

    starter =
      spawn(fn ->
        send(parent, {:reaper_started, AgentLink.Agent.Reaper.start_link(name: false)})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      Application.delete_env(:agent_link, :reaper_after_load)
      Application.delete_env(:agent_link, :reaper_before_lock)
      if is_binary(path), do: System.put_env("PATH", path)
      if Process.alive?(starter), do: Process.exit(starter, :kill)
      stop_named(AgentLink.Relay.Agent)
      stop_named(AgentLink.Uplink)
      stop_named(AgentLink.Agent.Reaper)

      if is_binary(kill) and os_alive?(other, other_started) and
           Integer.to_string(other) != System.pid() do
        System.cmd(kill, ["-s", "KILL", "--", Integer.to_string(other)], stderr_to_stdout: true)
      end
    end)

    paused =
      receive do
        {:between, paused} -> paused
      end

    on_exit(fn -> Process.exit(paused, :kill) end)

    Application.put_env(:agent_link, :reaper_before_lock, fn ->
      send(parent, {:locking, self()})
    end)

    retain = Task.async(fn -> AgentLink.Agent.Reaper.retain([{other, other_field}]) end)

    locker =
      receive do
        {:locking, locker} -> locker
      end

    case await_retain!(locker, retain) do
      :waiting ->
        send(paused, :resume)
        assert {:error, :noproc} = Task.await(retain, :infinity)

      {:done, {:error, :noproc}} ->
        send(paused, :resume)
    end

    result =
      receive do
        {:reaper_started, result} -> result
      end

    assert {:ok, reaper} = result
    assert {other, other_field} in AgentLink.Agent.Reaper.read_pairs()
    ref = Process.monitor(reaper)
    Process.exit(reaper, :kill)
    assert AgentLink.TestHelpers.await_down(ref, reaper) == :killed
    send(starter, :finish)
    Application.delete_env(:agent_link, :reaper_after_load)
    Application.delete_env(:agent_link, :reaper_before_lock)

    Application.put_env(:agent_link, :agent_module, AgentLink.LifecycleTest.Sticky)
    Application.put_env(:agent_link, :sticky_listener, self())
    sticky_link!()
    assert {:ok, _reaper} = AgentLink.Agent.Reaper.start_link()

    empty =
      Path.join(System.tmp_dir!(), "agentlink-no-kill-#{System.unique_integer([:positive])}")

    File.mkdir_p!(empty)
    System.put_env("PATH", empty)

    assert {:error, {:reap, :no_kill}} =
             AgentLink.Relay.Agent.start_link(
               transport: AgentLink.FakeTransport,
               transport_opts: [backoff: 60_000],
               watch_interval: nil
             )

    refute_received {:sticky_opened, _}
    assert os_alive?(other, other_started)
    Port.close(port)
  end

  test "a corrupt record is moved aside and the reaper starts" do
    path = AgentLink.Agent.Reaper.record_path()
    File.mkdir_p!(Path.dirname(path))

    for body <- ["x", :erlang.term_to_binary(:nope), :erlang.term_to_binary([{:bad, 1}])] do
      stop_named(AgentLink.Agent.Reaper)
      File.write!(path, body)
      assert {:ok, _} = AgentLink.Agent.Reaper.start_link()
      assert AgentLink.Agent.Reaper.read_pairs() == []
      assert :ok = AgentLink.Agent.Reaper.reap()
      names = File.ls!(Path.dirname(path))
      assert Enum.count(names, &String.contains?(&1, ".bin.bad-")) == 1
    end
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
    if mode == :relay, do: Application.put_env(:agent_link, :relay_token, "fixture")
    if port = opts[:port], do: Application.put_env(:agent_link, :port, port)
    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    sup
  end

  defp stop!(sup) do
    ref = Process.monitor(sup)
    Process.exit(sup, :shutdown)
    assert AgentLink.TestHelpers.await_down(ref, sup) == :shutdown
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

  defp await_accept!(port) do
    AgentLink.TestHelpers.await(fn -> accept?(port) end)
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

  defp await_retain!(pid, task) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        {:done, result}

      nil ->
        case Process.info(pid, :current_function) do
          {:current_function, {:global, :random_sleep, _}} ->
            :waiting

          _ ->
            await_retain!(pid, task)
        end
    end
  end

  defp await_sticky_opened do
    receive do
      {:sticky_opened, os_pid} -> os_pid
    end
  end

  defp pause_script do
    """
    import signal
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        signal.pause()
    """
  end

  defp pairs(binary) do
    {:agentlink_reaper, 1, records} = :erlang.binary_to_term(binary, [:safe])
    records
  end

  defp field_starttime!(pid) do
    {:ok, stat} = File.read("/proc/#{pid}/stat")
    {pos, 1} = stat |> :binary.matches(")") |> List.last()
    rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
    rest |> String.split(" ", trim: true) |> Enum.at(19)
  end

  defp stop_named(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      AgentLink.TestHelpers.await_down(ref, pid)
    else
      :ok
    end
  end

  defp stop_named(name) do
    if pid = Process.whereis(name), do: stop_named(pid), else: :ok
  end

  defp sticky_link! do
    dir = Path.join(System.tmp_dir!(), "agentlink-sticky-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    pidfile = Path.join(dir, "pids")
    script = Path.join(dir, "sticky.py")

    File.write!(script, """
    #!/usr/bin/env python3
    import signal
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    while True:
        signal.pause()
    """)

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
        "args" => [script]
      })

    path = Path.join(dir, "agent.link.json")
    File.write!(path, body)
    Application.put_env(:agent_link, :link_path, path)
    pidfile
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

defmodule AgentLink.LifecycleTest.Sticky do
  @moduledoc false
  @behaviour AgentLink.Agent

  @impl true
  def open(owner, %AgentLink.Agent.Launch{command: command, args: args}, cwd)
      when owner == self() do
    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, args},
        {:cd, cwd}
      ])

    if listener = Application.get_env(:agent_link, :sticky_listener) do
      {:os_pid, pid} = Port.info(port, :os_pid)
      send(listener, {:sticky_opened, pid})
    end

    {:ok, port}
  end

  def open(owner, %AgentLink.Agent.Launch{command: command}, _cwd) do
    {:error, "owner #{inspect(owner)} cannot open #{command}"}
  end

  @impl true
  def write(_port, _data), do: :ok

  @impl true
  def close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        case AgentLink.Agent.Process.starttime(pid) do
          field when is_binary(field) -> AgentLink.Agent.Reaper.retain([{pid, field}])
          _ -> :ok
        end

      _ ->
        :ok
    end

    {:error, :timeout}
  end
end
