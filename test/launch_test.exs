defmodule AgentLink.LaunchTest do
  @moduledoc """
  `AgentLink.Release.forward_signals/1` compiles a wrapper with `zig cc`.

  The inner program is Python standing in for the Burrito launcher. It forks
  a child, ignores `SIGTERM` and `SIGINT`, and exits with that child's status.
  The child forks a helper that ignores those signals, the way `beam.smp`
  keeps `erl_child_setup`. The child exits `17` after one signal and `18`
  after another, and `SIGKILL`s the helper. The test waits until the child
  has written its pid, then signals the wrapper. The wrapper's exit status
  is the assertion. A timer is not.
  """

  use ExUnit.Case, async: false

  test "forward_start_args passes the words after start" do
    dir = unique_dir("script")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    name = "agentlink"
    File.write!(Path.join(bin, name), unix_script())
    File.write!(Path.join(bin, name <> ".bat"), bat_script())
    release = %{path: dir, name: name}
    assert AgentLink.Release.forward_start_args(release) == release
    script = File.read!(Path.join(bin, name))
    assert script =~ "shift\n    start \"elixir\" --no-halt -- \"$@\""
    assert script =~ "start_iex)\n    start \"iex\" --werl"
    bat = File.read!(Path.join(bin, name <> ".bat"))
    refute bat =~ "for /f"
    refute bat =~ "tokens=1*"
    assert bat =~ "if not \"!REL_EXTRA!\" == \"--no-halt\" goto start_plain"
    assert bat =~ "set AGENTLINK_START_TAIL=%*"
    assert bat =~ "set AGENTLINK_START_TAIL=!AGENTLINK_START_TAIL:*%1 =!"
    assert bat =~ "set AGENTLINK_START_TAIL=-- !AGENTLINK_START_TAIL!"
    assert bat =~ ":start_plain\nset AGENTLINK_START_TAIL="
    assert bat =~ "--vm-args \"!RELEASE_VM_ARGS!\" !AGENTLINK_START_TAIL!"

    assert_raise RuntimeError, ~r/could not patch/, fn ->
      AgentLink.Release.forward_start_args(release)
    end
  end

  test "the linux wrapper exits with the VM status after SIGTERM" do
    dir = unique_dir("wrap")
    script = Path.join(dir, "inner.py")
    File.write!(script, inner_script())
    File.chmod!(script, 0o755)
    wrapped = Path.join(dir, "agentlink_linux")
    File.cp!(script, wrapped)
    release = %{name: :agentlink, burrito_out: dir}
    assert AgentLink.Release.forward_signals(release) == release
    assert File.regular?(wrapped)
    assert File.regular?(wrapped <> ".burrito")

    pidfile = Path.join(dir, "pids")

    port =
      Port.open({:spawn_executable, wrapped}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["beam", pidfile]}
      ])

    os_pid = port_os_pid(port)
    wrapper_started = starttime!(os_pid)

    on_exit(fn ->
      signal_if_same(os_pid, wrapper_started, "-KILL")
    end)

    assert read_ready!(port) == "ready\n"
    {burrito, beam} = read_pids!(pidfile)
    burrito_started = starttime!(burrito)
    beam_started = starttime!(beam)
    signal_if_same(os_pid, wrapper_started, "-TERM")
    assert await_status!(port) == 17
    await_gone!(burrito, burrito_started)
    await_gone!(beam, beam_started)
    await_gone!(os_pid, wrapper_started)
  end

  test "a process-group SIGTERM reaches the stand-in VM once" do
    {port, os_pid, wrapper_started, pidfile} = wrapped_beam!("group")
    assert read_ready!(port) == "ready\n"
    assert pgrp!(os_pid) == os_pid
    {burrito, beam} = read_pids!(pidfile)
    burrito_started = starttime!(burrito)
    beam_started = starttime!(beam)
    assert pgrp!(burrito) != os_pid
    assert pgrp!(beam) != os_pid
    track!(burrito, burrito_started)
    track!(beam, beam_started)
    signal_group!(os_pid, "TERM")
    assert await_status!(port) == 17
    await_gone!(burrito, burrito_started)
    await_gone!(beam, beam_started)
    await_gone!(os_pid, wrapper_started)
  end

  test "SIGINT reaches the stand-in VM once" do
    {port, os_pid, wrapper_started, pidfile} = wrapped_beam!("int")
    assert read_ready!(port) == "ready\n"
    {burrito, beam} = read_pids!(pidfile)
    burrito_started = starttime!(burrito)
    beam_started = starttime!(beam)
    track!(burrito, burrito_started)
    track!(beam, beam_started)
    signal_if_same(os_pid, wrapper_started, "-INT")
    assert await_status!(port) == 17
    await_gone!(burrito, burrito_started)
    await_gone!(beam, beam_started)
    await_gone!(os_pid, wrapper_started)
  end

  test "zig cc builds a wrapper for every shipped Burrito target" do
    dir = unique_dir("targets")

    for name <- ["agentlink_linux", "agentlink_macos", "agentlink_windows.exe"] do
      File.write!(Path.join(dir, name), "unwrapped")
    end

    assert AgentLink.Release.forward_signals(%{name: :agentlink, burrito_out: dir})
    assert File.read!(Path.join(dir, "agentlink_linux.burrito")) == "unwrapped"
    assert File.read!(Path.join(dir, "agentlink_macos.burrito")) == "unwrapped"
    assert File.read!(Path.join(dir, "agentlink_windows.burrito.exe")) == "unwrapped"
    assert file_brief!(Path.join(dir, "agentlink_linux")) =~ "ELF"
    assert file_brief!(Path.join(dir, "agentlink_macos")) =~ "Mach-O"
    assert file_brief!(Path.join(dir, "agentlink_windows.exe")) =~ "PE32+"
  end

  test "the linux wrapper passes arguments and a clean exit code" do
    dir = unique_dir("args")
    script = Path.join(dir, "inner.py")
    File.write!(script, inner_script())
    File.chmod!(script, 0o755)
    wrapped = Path.join(dir, "agentlink_linux")
    File.cp!(script, wrapped)
    assert AgentLink.Release.forward_signals(%{name: :agentlink, burrito_out: dir})
    out = Path.join(dir, "argv")

    {output, status} =
      System.cmd(wrapped, ["pass", out, "hello"], stderr_to_stdout: true)

    assert status == 0, output
    assert File.read!(out) == "pass\n#{out}\nhello"
  end

  defp unix_script do
    """
    case $1 in
      start)
        start "elixir" --no-halt
        ;;

      start_iex)
        start "iex" --werl
        ;;
    esac
    """
  end

  defp bat_script do
    """
    :start
    if "!RELEASE_DISTRIBUTION!" == "none" (
      set RELEASE_DISTRIBUTION_FLAG=
    ) else (
      set RELEASE_DISTRIBUTION_FLAG=--!RELEASE_DISTRIBUTION! "!RELEASE_NODE!"
    )
    "!REL_VSN_DIR!\\!REL_EXEC!.bat" !REL_EXTRA! ^
      --vm-args "!RELEASE_VM_ARGS!"
    goto end
    """
  end

  defp inner_script do
    ~S"""
    #!/usr/bin/env python3
    import os
    import signal
    import sys

    mode = sys.argv[1]
    if mode == "pass":
        with open(sys.argv[2], "w", encoding="utf-8") as handle:
            handle.write("\n".join(sys.argv[1:]))
        raise SystemExit(0)
    if mode != "beam":
        raise SystemExit(2)

    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    ready_read, ready_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_read)
        helper = os.fork()
        if helper == 0:
            os.close(ready_write)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            while True:
                signal.pause()
        count = {"n": 0}
        def stop(_signum, _frame):
            count["n"] += 1
            os.kill(helper, signal.SIGKILL)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        os.write(ready_write, b"1")
        os.close(ready_write)
        while count["n"] == 0:
            signal.pause()
        pending = signal.sigpending()
        if count["n"] != 1 or signal.SIGTERM in pending or signal.SIGINT in pending:
            raise SystemExit(18)
        raise SystemExit(17)

    os.close(ready_write)
    os.read(ready_read, 1)
    os.close(ready_read)
    with open(sys.argv[2], "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()} {pid}\n")
    sys.stdout.write("ready\n")
    sys.stdout.flush()
    _wpid, status = os.waitpid(pid, 0)
    raise SystemExit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
    """
  end

  defp wrapped_beam!(name) do
    dir = unique_dir(name)
    script = Path.join(dir, "inner.py")
    File.write!(script, inner_script())
    File.chmod!(script, 0o755)
    wrapped = Path.join(dir, "agentlink_linux")
    File.cp!(script, wrapped)
    assert AgentLink.Release.forward_signals(%{name: :agentlink, burrito_out: dir})
    pidfile = Path.join(dir, "pids")

    port =
      Port.open({:spawn_executable, wrapped}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["beam", pidfile]}
      ])

    os_pid = port_os_pid(port)
    wrapper_started = starttime!(os_pid)
    track!(os_pid, wrapper_started)
    {port, os_pid, wrapper_started, pidfile}
  end

  defp track!(pid, starttime) do
    on_exit(fn -> signal_if_same(pid, starttime, "-KILL") end)
  end

  defp signal_group!(pgid, name) do
    if pgid > 1 and Integer.to_string(pgid) != System.pid() do
      System.cmd("kill", ["-s", name, "--", Integer.to_string(-pgid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp pgrp!(pid) do
    {:ok, stat} = File.read("/proc/#{pid}/stat")
    {pos, _} = List.last(:binary.matches(stat, ")"))
    rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
    fields = String.split(rest, " ", trim: true)
    {pgrp, ""} = Integer.parse(Enum.at(fields, 2))
    pgrp
  end

  defp file_brief!(path) do
    {output, status} = System.cmd("file", ["--brief", path], stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp unique_dir(name) do
    dir = Path.join(System.tmp_dir!(), "agentlink-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp read_ready!(port) do
    collect(port, "ready\n", "")
  end

  defp collect(port, expected, acc) do
    if String.contains?(acc, expected) do
      acc
    else
      receive do
        {^port, {:data, chunk}} -> collect(port, expected, acc <> chunk)
        {^port, {:exit_status, status}} -> flunk("wrapper exited #{status} before ready: #{acc}")
      end
    end
  end

  defp read_pids!(pidfile) do
    [parent, child] = pidfile |> File.read!() |> String.split()
    {String.to_integer(parent), String.to_integer(child)}
  end

  defp await_status!(port) do
    receive do
      {^port, {:data, _chunk}} -> await_status!(port)
      {^port, {:exit_status, status}} -> status
    end
  end

  defp port_os_pid(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    pid
  end

  defp signal_if_same(pid, starttime, flag) do
    if same?(pid, starttime) and pid > 1 and Integer.to_string(pid) != System.pid() do
      System.cmd("kill", [flag, Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp starttime!(pid) do
    {:ok, stat} = File.read("/proc/#{pid}/stat")
    {:ok, %{starttime: starttime}} = AgentLink.OwnedStop.parse_stat(stat)
    starttime
  end

  defp same?(pid, starttime) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case AgentLink.OwnedStop.parse_stat(stat) do
          {:ok, %{starttime: ^starttime, state: state}} -> state != "Z"
          _ -> false
        end

      _ ->
        false
    end
  end

  defp await_gone!(pid, starttime) do
    if same?(pid, starttime) do
      receive do
      after
        0 -> await_gone!(pid, starttime)
      end
    else
      :ok
    end
  end
end
