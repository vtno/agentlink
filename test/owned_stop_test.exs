defmodule AgentLink.OwnedStopTest do
  use ExUnit.Case, async: false

  test "SIGTERM to a launcher pid leaves the child it started" do
    assert {:unix, :linux} = :os.type()
    fixture = start_fixture!()

    System.cmd("kill", ["-TERM", Integer.to_string(fixture.parent)], stderr_to_stdout: true)
    await_dead!(fixture.parent)
    assert AgentLink.OwnedStop.descendants(fixture.parent) == []
    assert running?(fixture.child)

    System.cmd("kill", ["-KILL", Integer.to_string(fixture.child)], stderr_to_stdout: true)
    await_dead!(fixture.child)
  end

  test "stop_os_pid kills the child after its port owner exits" do
    assert {:unix, :linux} = :os.type()
    unrelated = start_unrelated!()
    dir = Path.join(System.tmp_dir!(), "agentlink-owned-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "launcher.py")
    parent_file = Path.join(dir, "parent")
    child_file = Path.join(dir, "child")
    File.write!(script, launcher_script())

    parent = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, System.find_executable("python3")}, [
            :binary,
            :exit_status,
            {:args, [script, parent_file, child_file]}
          ])

        {:os_pid, pid} = Port.info(port, :os_pid)
        send(parent, {:started, port, pid})

        receive do
          :exit -> :ok
        end
      end)

    {port, launcher} = await_started!()
    child = read_pid!(child_file)
    send(owner, :exit)
    await_exit!(owner)

    assert Port.info(port, :os_pid) == nil
    assert running?(child)

    pids = AgentLink.OwnedStop.stop_os_pid(launcher)
    assert launcher in pids
    assert child in pids
    refute unrelated.pid in pids
    refute running?(launcher)
    refute running?(child)
    assert running?(unrelated.pid)

    System.cmd("kill", ["-KILL", Integer.to_string(unrelated.pid)], stderr_to_stdout: true)
    await_dead!(unrelated.pid)
    File.rm_rf(dir)
  end

  test "stop_port kills that child and leaves an unrelated process" do
    assert {:unix, :linux} = :os.type()
    fixture = start_fixture!()
    unrelated = start_unrelated!()

    pids = AgentLink.OwnedStop.stop_port(fixture.port)

    assert fixture.parent in pids
    assert fixture.child in pids
    refute unrelated.pid in pids
    refute running?(fixture.parent)
    refute running?(fixture.child)
    assert running?(unrelated.pid)

    System.cmd("kill", ["-KILL", Integer.to_string(unrelated.pid)], stderr_to_stdout: true)
    await_dead!(unrelated.pid)
  end

  defp start_fixture! do
    dir = Path.join(System.tmp_dir!(), "agentlink-owned-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "launcher.py")
    parent_file = Path.join(dir, "parent")
    child_file = Path.join(dir, "child")
    File.write!(script, launcher_script())

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        {:args, [script, parent_file, child_file]}
      ])

    on_exit(fn ->
      for path <- [parent_file, child_file],
          pid <- List.wrap(read_pid(path)) do
        AgentLink.OwnedStop.stop_os_pid(pid)
      end

      File.rm_rf(dir)
    end)

    parent = read_pid!(parent_file)
    child = read_pid!(child_file)
    %{port: port, parent: parent, child: child, dir: dir}
  end

  defp start_unrelated! do
    dir = Path.join(System.tmp_dir!(), "agentlink-other-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "other.py")
    pid_file = Path.join(dir, "pid")
    File.write!(script, unrelated_script())

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        {:args, [script, pid_file]}
      ])

    on_exit(fn ->
      if pid = read_pid(pid_file) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      if Port.info(port), do: Port.close(port)
      File.rm_rf(dir)
    end)

    %{port: port, pid: read_pid!(pid_file)}
  end

  defp launcher_script do
    """
    import os
    import signal
    import sys

    parent_file, child_file = sys.argv[1], sys.argv[2]
    pid = os.fork()
    if pid == 0:
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        with open(child_file, "w") as handle:
            handle.write(str(os.getpid()))
        signal.pause()
    else:
        def die(_signum, _frame):
            os._exit(0)

        signal.signal(signal.SIGTERM, die)
        with open(parent_file, "w") as handle:
            handle.write(str(os.getpid()))
        signal.pause()
    """
  end

  defp unrelated_script do
    """
    import os
    import signal
    import sys

    with open(sys.argv[1], "w") as handle:
        handle.write(str(os.getpid()))
    signal.pause()
    """
  end

  defp read_pid!(path) do
    read_pid(path) || await_pid!(path)
  end

  defp await_pid!(path) do
    receive do
    after
      0 ->
        case read_pid(path) do
          nil -> await_pid!(path)
          pid -> pid
        end
    end
  end

  defp read_pid(path) do
    case File.read(path) do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {pid, ""} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp await_started! do
    receive do
      {:started, port, pid} -> {port, pid}
    after
      0 -> await_started!()
    end
  end

  defp await_exit!(pid) do
    receive do
    after
      0 ->
        if Process.alive?(pid), do: await_exit!(pid), else: :ok
    end
  end

  defp await_dead!(pid) do
    receive do
    after
      0 ->
        if running?(pid), do: await_dead!(pid), else: :ok
    end
  end

  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case :binary.matches(stat, ") ") do
          [] ->
            true

          matches ->
            {pos, _} = List.last(matches)
            rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
            not String.starts_with?(rest, "Z ")
        end

      _ ->
        false
    end
  end
end
