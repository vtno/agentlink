defmodule AgentLink.Agent.ProcessTest do
  @moduledoc """
  Direct tests for `AgentLink.Agent.Process`.

  The executable is the OTP runtime. On Unix the file is `erlexec`. On
  Windows the file is `erl.exe`. The test compiles
  `agentlink_process_fixture.erl` with `:compile.file/2`. The fixture
  reads handshake lines from stdin. `ping`, `argv`, `cwd`, `env`, `echo`,
  `stderr`, and `exit` each reply before the next line. The tests do not
  call `Process.sleep/1`.

  `{port, {:exit_status, 17}}` arrives while the port is open, and the os
  pid is then gone. After `close/1`, the fixture sees stdin EOF, writes
  `eof` to the stamp file, and exits. The test waits until that file
  contains `eof` and the os pid is gone. A timer is not the success
  condition.

  These tests were run on Linux x86_64. macOS and Windows were not run.
  The symlink cases use `File.ln_s!/2` and were run on Linux.
  """

  use ExUnit.Case, async: false

  alias AgentLink.Agent.Launch
  alias AgentLink.Agent.Process, as: AgentProcess

  setup_all do
    beam_dir =
      Path.join(
        System.tmp_dir!(),
        "agentlink-process-beams-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(beam_dir)
    on_exit(fn -> File.rm_rf!(beam_dir) end)
    compile_fixture!(beam_dir)
    exe = otp_executable()
    assert File.regular?(exe)
    %{beam_dir: beam_dir, exe: exe}
  end

  test "open from another process returns the owner error and does not call the finder" do
    owner = self()
    command = "agentlink-not-spawned"
    launch = %Launch{command: command, args: []}
    cwd = File.cwd!()

    finder = fn _command ->
      send(owner, :finder_called)
      nil
    end

    spawn(fn ->
      result = AgentProcess.open(owner, launch, cwd, finder)
      send(owner, {:opened, result})
    end)

    receive do
      :finder_called ->
        flunk("finder must not be called")

      {:opened, result} ->
        assert result ==
                 {:error,
                  "AgentLink.Agent.Process.open/3 must be called from the owner (#{inspect(owner)}) for #{command}"}
    end
  end

  test "a missing bare name returns the finder error" do
    command = "agentlink-missing-#{System.unique_integer([:positive])}"
    launch = %Launch{command: command, args: []}

    assert AgentProcess.open(self(), launch, File.cwd!()) ==
             {:error, "could not find #{command}"}
  end

  test "a finder result is executed", %{beam_dir: beam_dir, exe: exe} do
    command = "agentlink-fixture"

    finder = fn
      ^command -> exe
      other -> flunk("finder called for #{inspect(other)}")
    end

    dir = make_dir()
    {port, _os_pid, _stamp} = opened!(command, fixture_args(beam_dir, []), dir, finder)
    ping!(port)
  end

  test "a host-absolute path does not call the finder", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    {port, _os_pid, _stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))
    ping!(port)
  end

  test "a symlink to the executable is a regular file", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    link = Path.join(dir, "erlexec-link")
    File.ln_s!(exe, link)
    assert {:ok, %File.Stat{type: :regular}} = File.stat(link)

    {port, _os_pid, _stamp} = opened!(link, fixture_args(beam_dir, []), dir, refuse_finder(link))
    ping!(port)
  end

  test "a dangling symlink returns the stat error" do
    dir = make_dir()
    link = Path.join(dir, "dangling")
    File.ln_s!(Path.join(dir, "missing-target"), link)

    assert AgentProcess.open(self(), %Launch{command: link, args: []}, dir, refuse_finder(link)) ==
             {:error, "could not stat #{link}: :enoent"}
  end

  test "a directory is not a regular file" do
    dir = make_dir()
    before = owned_ports()

    assert AgentProcess.open(self(), %Launch{command: dir, args: []}, dir, refuse_finder(dir)) ==
             {:error, "#{dir} is a directory, not a regular file"}

    assert owned_ports() == before
  end

  test "a missing host-absolute path returns the stat error" do
    dir = make_dir()
    path = Path.join(dir, "missing-exe")
    refute File.exists?(path)

    assert AgentProcess.open(self(), %Launch{command: path, args: []}, dir, refuse_finder(path)) ==
             {:error, "could not stat #{path}: :enoent"}
  end

  test "a regular file without execute permission returns the spawn error" do
    dir = make_dir()
    path = Path.join(dir, "not-a-program")
    File.write!(path, "not a program")
    File.chmod!(path, 0o644)

    assert {:error, "could not open " <> rest} =
             AgentProcess.open(self(), %Launch{command: path, args: []}, dir, refuse_finder(path))

    assert String.starts_with?(rest, path <> ": ")
  end

  test "a command that is not absolute on this host is not executed", %{
    beam_dir: beam_dir,
    exe: exe
  } do
    vm_cwd = make_dir()
    launch_cwd = make_dir()
    stamp = Path.join(launch_cwd, "rejected-stamp")
    previous = File.cwd!()
    File.cd!(vm_cwd)

    try do
      for root <- [vm_cwd, launch_cwd], command <- rejected_commands() do
        plant_trap(root, command, exe)
      end

      System.put_env("AGENTLINK_FIXTURE_STAMP", stamp)

      for command <- rejected_commands() do
        before = owned_ports()
        launch = %Launch{command: command, args: fixture_args(beam_dir, [])}

        assert AgentProcess.open(self(), launch, launch_cwd, refuse_finder(command)) ==
                 {:error, "#{command} is not an executable path on this host"}

        refute File.exists?(stamp)
        assert owned_ports() == before
      end
    after
      System.delete_env("AGENTLINK_FIXTURE_STAMP")
      File.cd!(previous)
    end
  end

  test "plain args round-trip through argv", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    plain = ["hello world", ""]

    {port, _os_pid, _stamp} =
      opened!(exe, fixture_args(beam_dir, plain), dir, refuse_finder(exe))

    exchange(port, "argv\n", "2\n11\nhello world\n0\n\n")
  end

  test "cwd is the directory passed to open/3", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    {port, _os_pid, _stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))
    exchange(port, "cwd\n", dir <> "\n")
  end

  test "env returns the variable set before open", %{beam_dir: beam_dir, exe: exe} do
    key = "AGENTLINK_PROCESS_PROBE"
    value = "probe-#{System.unique_integer([:positive])}"
    System.put_env(key, value)

    try do
      dir = make_dir()
      {port, _os_pid, _stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))
      exchange(port, "env #{key}\n", value <> "\n")
    after
      System.delete_env(key)
    end
  end

  test "echo returns the bytes written to stdin", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    {port, _os_pid, _stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))
    exchange(port, "echo hello world\n", "hello world\n")
  end

  test "stderr stays off stdout", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    token = "agentlink-stderr-token"
    side = Path.join(dir, "stderr-side")
    {port, _os_pid, _stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))

    assert AgentProcess.write(port, "stderr #{side} #{token}\n") == :ok
    acc = collect(port, "stderr-ok\n", "")
    assert acc == "stderr-ok\n"
    refute String.contains?(acc, token)
    assert File.read!(side) == token
  end

  test "exit delivers status 17 and the os pid is gone", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    {port, os_pid, _stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))
    assert AgentProcess.write(port, "exit\n") == :ok
    assert await_exit_status(port) == 17
    refute os_alive?(os_pid)
  end

  test "write and close report a closed port", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    {port, os_pid, stamp} = opened!(exe, fixture_args(beam_dir, []), dir, refuse_finder(exe))
    ping!(port)
    assert AgentProcess.close(port) == :ok
    assert AgentProcess.write(port, "ping\n") == :closed
    assert AgentProcess.write(self(), "ping\n") == :closed
    assert AgentProcess.close(port) == :ok
    wait_reaped!(os_pid, stamp)
  end

  test "a deleted executable path fails the next open", %{beam_dir: beam_dir, exe: exe} do
    dir = make_dir()
    link = Path.join(dir, "launched-link")
    File.ln_s!(exe, link)
    args = fixture_args(beam_dir, [])
    {port, os_pid, _stamp} = opened!(link, args, dir, refuse_finder(link))
    ping!(port)
    assert AgentProcess.write(port, "exit\n") == :ok
    assert await_exit_status(port) == 17
    refute os_alive?(os_pid)

    File.rm!(link)
    assert File.regular?(exe)

    assert AgentProcess.open(self(), %Launch{command: link, args: args}, dir, refuse_finder(link)) ==
             {:error, "could not stat #{link}: :enoent"}
  end

  defp compile_fixture!(beam_dir) do
    source = Path.expand("fixtures/agentlink_process_fixture.erl", __DIR__)

    case :compile.file(String.to_charlist(source), [
           {:outdir, String.to_charlist(beam_dir)},
           :return_errors,
           :report_errors,
           :report_warnings
         ]) do
      {:ok, :agentlink_process_fixture} ->
        :ok

      {:ok, :agentlink_process_fixture, _binary} ->
        :ok

      other ->
        flunk("could not compile #{source}: #{inspect(other)}")
    end
  end

  defp otp_executable do
    root = to_string(:code.root_dir())
    version = to_string(:erlang.system_info(:version))

    name =
      case :os.type() do
        {:win32, _} -> "erl.exe"
        _ -> "erlexec"
      end

    Path.join([root, "erts-" <> version, "bin", name])
  end

  defp fixture_args(beam_dir, plain) do
    ["-noshell", "-pa", beam_dir, "-run", "agentlink_process_fixture", "start", "--" | plain]
  end

  defp rejected_commands do
    case :os.type() do
      {:win32, _} ->
        [
          "/usr/bin/agentlink-trap",
          "./agentlink-trap",
          "subdir/agentlink-trap"
        ]

      _ ->
        [
          "C:\\agentlink-trap.exe",
          "\\\\server\\share\\app.exe",
          "D:/agentlink-trap.exe",
          "./agentlink-trap"
        ]
    end
  end

  defp opened!(command, args, cwd, finder) do
    stamp = Path.join(cwd, "stamp")
    File.rm(stamp)
    System.put_env("AGENTLINK_FIXTURE_STAMP", stamp)

    try do
      launch = %Launch{command: command, args: args}

      case AgentProcess.open(self(), launch, cwd, finder) do
        {:ok, port} ->
          os_pid = os_pid!(port)

          on_exit(fn ->
            AgentProcess.close(port)

            if os_alive?(os_pid) do
              wait_reaped!(os_pid, stamp)
            end
          end)

          {port, os_pid, stamp}

        {:error, message} ->
          flunk(message)
      end
    after
      System.delete_env("AGENTLINK_FIXTURE_STAMP")
    end
  end

  defp ping!(port), do: exchange(port, "ping\n", "pong\n")

  defp exchange(port, command, expected) do
    assert AgentProcess.write(port, command) == :ok
    acc = collect(port, expected, "")
    assert acc == expected
    acc
  end

  defp collect(port, expected, acc) do
    if String.contains?(acc, expected) do
      acc
    else
      receive do
        {^port, {:data, chunk}} ->
          collect(port, expected, acc <> chunk)
      end
    end
  end

  defp await_exit_status(port) do
    receive do
      {^port, {:data, _chunk}} ->
        await_exit_status(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  # The child writes the stamp after stdin closes, then exits. ExUnit's
  # timeout is the failure path. A timer is not the success condition.
  defp wait_reaped!(os_pid, stamp) do
    receive do
    after
      0 ->
        if stamp_eof?(stamp) and not os_alive?(os_pid) do
          :ok
        else
          wait_reaped!(os_pid, stamp)
        end
    end
  end

  defp stamp_eof?(stamp) do
    case File.read(stamp) do
      {:ok, body} -> String.contains?(body, "eof")
      _ -> false
    end
  end

  defp os_pid!(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  defp os_alive?(os_pid) do
    case :os.type() do
      {:win32, _} ->
        {output, _status} =
          System.cmd("tasklist", ["/FI", "PID eq #{os_pid}", "/FO", "CSV", "/NH"])

        String.contains?(output, Integer.to_string(os_pid))

      _ ->
        {_output, status} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])
        status == 0
    end
  end

  defp owned_ports do
    self = self()

    Enum.filter(Port.list(), fn port ->
      Port.info(port, :connected) == {:connected, self}
    end)
  end

  defp make_dir do
    dir = Path.join(System.tmp_dir!(), "agentlink-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp plant_trap(root, command, exe) do
    root = Path.expand(root)
    path = Path.expand(command, root)

    if contained?(path, root) do
      File.mkdir_p!(Path.dirname(path))
      File.rm(path)
      File.ln_s!(exe, path)
      assert {:ok, %File.Stat{type: :regular}} = File.stat(path)
    end
  end

  defp contained?(path, root) do
    relative = Path.relative_to(path, root)
    relative not in [path, "."] and not String.starts_with?(relative, "..")
  end

  defp refuse_finder(command) do
    fn _name ->
      flunk("finder must not be called for #{inspect(command)}")
    end
  end
end
