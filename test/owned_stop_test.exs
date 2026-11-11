defmodule AgentLink.OwnedStopTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Linux tests read `/proc` and spawn processes. They are skipped when
  `:os.type/0` is not `{:unix, :linux}`. That skip is not a claim that
  `AgentLink.OwnedStop` stops a process tree on macOS or Windows.
  """

  @linux_skip if(match?({:unix, :linux}, :os.type()),
                do: false,
                else: "OwnedStop reads /proc starttime. It was run on Linux only."
              )

  @tag skip: @linux_skip
  test "SIGTERM leaves the recorded child, and stop kills that child" do
    fixture = start_fixture!()
    unrelated = start_unrelated!()

    System.cmd("kill", ["-TERM", Integer.to_string(fixture.parent)], stderr_to_stdout: true)
    await_dead!(fixture.parent)
    assert AgentLink.OwnedStop.descendants(fixture.parent) == []
    assert running?(fixture.child)

    signaled = AgentLink.OwnedStop.stop(fixture.owned)
    assert Enum.any?(signaled, &(&1.pid == fixture.child))
    refute Enum.any?(signaled, &(&1.pid == unrelated.pid))
    refute running?(fixture.child)
    assert AgentLink.OwnedStop.stop(fixture.owned) == []
    assert running?(unrelated.pid)
  end

  @tag skip: @linux_skip
  test "stop kills the child after its port owner exits" do
    unrelated = start_unrelated!()
    fixture = start_owner!()
    port_ref = Port.monitor(fixture.port)

    send(fixture.owner, :exit)
    await_exit!(fixture.owner)

    receive do
      {:DOWN, ^port_ref, :port, _, _reason} -> :ok
    end

    assert Port.info(fixture.port, :os_pid) == nil
    assert running?(fixture.child)

    signaled = AgentLink.OwnedStop.stop(fixture.owned)
    assert Enum.any?(signaled, &(&1.pid == fixture.launcher))
    assert Enum.any?(signaled, &(&1.pid == fixture.child))
    refute Enum.any?(signaled, &(&1.pid == unrelated.pid))
    refute running?(fixture.launcher)
    refute running?(fixture.child)
    assert AgentLink.OwnedStop.stop(fixture.owned) == []
    assert running?(unrelated.pid)
  end

  @tag skip: @linux_skip
  test "release stops the owner and the child when the body never signals the owner" do
    unrelated = start_unrelated!()
    fixture = start_owner!()

    assert Process.alive?(fixture.owner)
    assert running?(fixture.child)

    release(fixture)
    refute Process.alive?(fixture.owner)
    refute running?(fixture.child)
    assert AgentLink.OwnedStop.stop(fixture.owned) == []
    assert running?(unrelated.pid)
  end

  test "parse_stat reads starttime from field 22" do
    fields = [
      "S",
      "1",
      "10",
      "10",
      "0",
      "-1",
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      "0",
      "20",
      "0",
      "1",
      "0",
      "0",
      "555"
    ]

    assert Enum.at(fields, 19) == "555"
    stat = "10 (a) b) " <> Enum.join(fields, " ")

    assert {:ok, %{pid: 10, ppid: 1, state: "S", starttime: 555}} =
             AgentLink.OwnedStop.parse_stat(stat)
  end

  test "select ignores a reused pid and keeps a reparented child" do
    captured = [
      %{pid: 10, starttime: 100},
      %{pid: 11, starttime: 200}
    ]

    reused = %{
      10 => %{pid: 10, starttime: 999, ppid: 1, state: "S"},
      12 => %{pid: 12, starttime: 1000, ppid: 10, state: "S"},
      11 => %{pid: 11, starttime: 200, ppid: 1, state: "S"}
    }

    assert [%{pid: 11, starttime: 200}] = AgentLink.OwnedStop.select(captured, reused)

    living = %{
      10 => %{pid: 10, starttime: 100, ppid: 1, state: "S"},
      12 => %{pid: 12, starttime: 300, ppid: 10, state: "S"}
    }

    assert MapSet.new([
             %{pid: 10, starttime: 100},
             %{pid: 12, starttime: 300}
           ]) == MapSet.new(AgentLink.OwnedStop.select([%{pid: 10, starttime: 100}], living))
  end

  test "confirm_gone raises when the recorded process is still present" do
    target = %{pid: 10, starttime: 100}

    assert_raise RuntimeError, ~r/pid=10 recorded_starttime=100/, fn ->
      AgentLink.OwnedStop.confirm_gone([target], 2, fn ^target -> true end)
    end
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

    parent = read_pid!(parent_file)
    child = read_pid!(child_file)

    owned =
      case AgentLink.OwnedStop.capture(parent) do
        {:ok, owned} -> owned
        :error -> flunk("could not read /proc starttime for #{parent}")
      end

    on_exit(fn ->
      AgentLink.OwnedStop.stop(owned)
      File.rm_rf(dir)
    end)

    %{port: port, parent: parent, child: child, owned: owned, dir: dir}
  end

  defp start_owner! do
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

    on_exit(fn -> send(owner, :exit) end)
    {port, launcher} = await_started!()
    child = read_pid!(child_file)

    owned =
      case AgentLink.OwnedStop.capture(launcher) do
        {:ok, owned} -> owned
        :error -> flunk("could not read /proc starttime for #{launcher}")
      end

    on_exit(fn ->
      release(%{owner: owner, owned: owned, dir: dir})
    end)

    %{port: port, owner: owner, launcher: launcher, child: child, owned: owned, dir: dir}
  end

  defp release(fixture) do
    if is_pid(fixture.owner) and Process.alive?(fixture.owner), do: send(fixture.owner, :exit)
    AgentLink.OwnedStop.stop(fixture.owned)
    File.rm_rf(fixture.dir)
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

    pid = read_pid!(pid_file)

    owned =
      case AgentLink.OwnedStop.capture(pid) do
        {:ok, owned} -> owned
        :error -> flunk("could not read /proc starttime for #{pid}")
      end

    on_exit(fn ->
      AgentLink.OwnedStop.stop(owned)
      if Port.info(port), do: Port.close(port)
      File.rm_rf(dir)
    end)

    %{port: port, pid: pid, owned: owned}
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
        case AgentLink.OwnedStop.parse_stat(stat) do
          {:ok, %{state: "Z"}} -> false
          {:ok, _} -> true
          :error -> true
        end

      _ ->
        false
    end
  end
end
