defmodule AgentLink.ReleaseLifecycleTest do
  @moduledoc """
  A plain Mix release, built with `AGENTLINK_BURRITO=0`.

  `mix test --only release` runs these tests. The default suite excludes
  `:release`. Each test sets `RELEASE_SYS_CONFIG` and `HOME`. `:cli` is
  `true`. `:agent_stop_timeout` in that config is `0`, so a hold fixture
  that ignores `SIGTERM` is `SIGKILL`ed without the default `5000` wait.
  The test waits until the recorded start time no longer matches. Output
  shown on failure has the fixture token replaced with `[token]`.
  """

  use ExUnit.Case, async: false

  @moduletag :release
  @moduletag timeout: 180_000

  setup_all do
    root = File.cwd!()

    {output, status} =
      System.cmd("mix", ["release", "--overwrite"],
        cd: root,
        env: [{"MIX_ENV", "prod"}, {"AGENTLINK_BURRITO", "0"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    bin = Path.join(root, "_build/prod/rel/agentlink/bin/agentlink")
    assert File.read!(bin) =~ "start \"elixir\" --no-halt -- \"$@\""
    %{bin: bin}
  end

  setup context do
    dir = Path.join(System.tmp_dir!(), "agentlink-rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "home"))
    File.mkdir_p!(Path.join(dir, "tmp"))
    on_exit(fn -> File.rm_rf!(dir) end)
    Map.put(context, :dir, dir)
  end

  test "start with no words keeps a sys.config plane", %{bin: bin, dir: dir} do
    port_num = 18_461
    sys = write_sys!(dir, plane_config(port_num))
    {port, os_pid, started} = boot!(bin, ["start"], env(dir, "lifeplane", sys))
    log = await_listen!(port, port_num, "")
    assert shown(log) =~ "Waiting for the uplink to connect."
    refute shown(log) =~ "The agent relay on this machine is starting."
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 0
    await_closed!(port_num)
    await_gone!(os_pid, started)
  end

  test "start plane replaces a sys.config all", %{bin: bin, dir: dir} do
    port_num = 18_462
    sys = write_sys!(dir, all_config(port_num))

    {port, os_pid, started} =
      boot!(bin, ["start", "plane", "--port", "#{port_num}"], env(dir, "lifeplaneargv", sys))

    log = await_listen!(port, port_num, "")
    assert shown(log) =~ "Waiting for the uplink to connect."
    refute shown(log) =~ "The agent relay on this machine is starting."
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 0
    await_closed!(port_num)
  end

  test "start relay does not listen and stop reaps the hold fixture", %{bin: bin, dir: dir} do
    port_num = 18_463
    pidfile = hold_link!(dir)
    sys = write_sys!(dir, plane_config(port_num))

    {port, os_pid, started} =
      boot!(bin, ["start", "relay", "--token", "sekret"], env(dir, "liferelay", sys))

    {parent, child, log} = await_hold!(port, pidfile, "")
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    track!(parent, parent_started)
    track!(child, child_started)
    assert shown(log) =~ "The uplink will dial the plane_url"
    refute accept?(port_num)
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 0
    await_gone!(parent, parent_started)
    await_gone!(child, child_started)
    await_gone!(os_pid, started)
    refute accept?(port_num)
  end

  test "start with no words runs all and SIGTERM reaps the hold fixture", %{bin: bin, dir: dir} do
    port_num = 18_464
    pidfile = hold_link!(dir)
    sys = write_sys!(dir, all_config(port_num))
    {port, os_pid, started} = boot!(bin, ["start"], env(dir, "lifeall", sys))
    log = await_listen!(port, port_num, "")
    {parent, child, log} = await_hold!(port, pidfile, log)
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    track!(parent, parent_started)
    track!(child, child_started)
    assert shown(log) =~ "The agent relay on this machine is starting."
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 0
    await_closed!(port_num)
    await_gone!(parent, parent_started)
    await_gone!(child, child_started)
  end

  test "bin/agentlink stop shuts a plane down", %{bin: bin, dir: dir} do
    port_num = 18_465
    sys = write_sys!(dir, plane_config(port_num))
    env = env(dir, "lifestop", sys)
    {port, _os_pid, _started} = boot!(bin, ["start", "plane"], env)
    log = await_listen!(port, port_num, "")
    {output, status} = System.cmd(bin, ["stop"], env: env, stderr_to_stdout: true)
    assert status == 0, shown(output)
    assert await_status!(port, log <> output) == 0
    await_closed!(port_num)
  end

  test "start connect with stdin closed exits 0", %{bin: bin, dir: dir} do
    port_num = 18_466
    sys = write_sys!(dir, plane_config(port_num))
    closer = write_closer!(dir)
    python = System.find_executable("python3")
    stdbuf = System.find_executable("stdbuf")

    {port, _os_pid, _started} =
      boot_program!(
        python,
        [
          closer,
          stdbuf,
          "-oL",
          "-eL",
          bin,
          "start",
          "connect",
          "--plane",
          "ws://127.0.0.1:9/acp",
          "--token",
          "sekret"
        ],
        env(dir, "lifeconnect0", sys)
      )

    {status, log} = await_exit!(port, "")
    assert status == 0, shown(log)
    refute shown(log) =~ "Waiting for the uplink to connect."
    refute shown(log) =~ "The agent relay on this machine is starting."
    refute shown(log) =~ "No link file"
    refute accept?(port_num)
  end

  test "SIGTERM during connect exits 1", %{bin: bin, dir: dir} do
    sys = write_sys!(dir, connect_config())
    env = env(dir, "lifeconnect1", sys)

    {port, os_pid, started} =
      boot!(
        bin,
        ["start", "connect", "--plane", "ws://127.0.0.1:9/acp", "--token", "sekret"],
        env
      )

    log = await_running!(bin, env, port, os_pid, "")
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 1
    await_gone!(os_pid, started)
  end

  defp boot!(bin, args, env) do
    boot_program!(System.find_executable("stdbuf"), ["-oL", "-eL", bin | args], env)
  end

  defp boot_program!(program, args, env) do
    port =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:env,
         Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)}
      ])

    os_pid = port_os_pid(port)
    started = starttime!(os_pid)
    on_exit(fn -> signal_if_same!(os_pid, started, "-KILL") end)
    {port, os_pid, started}
  end

  defp env(dir, node, sys) do
    [
      {"HOME", Path.join(dir, "home")},
      {"PATH", System.get_env("PATH") || ""},
      {"LANG", "C.UTF-8"},
      {"RELEASE_NODE", node},
      {"RELEASE_COOKIE", "agentlinktest"},
      {"RELEASE_SYS_CONFIG", sys},
      {"RELEASE_TMP", Path.join(dir, "tmp")}
    ]
  end

  defp plane_config(port) do
    common(port, "plane")
  end

  defp all_config(port) do
    common(port, "all")
  end

  defp connect_config do
    common(18_467, "connect") <>
      ",{connect_plane,<<\"ws://127.0.0.1:9/acp\">>},{connect_token,<<\"sekret\">>}"
  end

  defp common(port, mode) do
    url = "ws://127.0.0.1:#{port}/agent"

    "{port,#{port}},{mode,#{mode}},{plane_url,<<\"#{url}\">>},{master_token,<<\"sekret\">>}," <>
      "{agent_module,'Elixir.AgentLink.Agent.Process'},{access,'Elixir.AgentLink.Access.Single'}," <>
      "{cli,true},{agent_stop_timeout,0}"
  end

  defp write_sys!(dir, pairs) do
    path = Path.join(dir, "sys")

    File.write!(
      path <> ".config",
      "%% coding: utf-8\n%% RUNTIME_CONFIG=false\n[{agent_link,[#{pairs}]},{logger,[{level,warning}]}].\n"
    )

    path
  end

  defp hold_link!(dir) do
    root = Path.join(dir, "home/.agentlink")
    File.mkdir_p!(root)
    pidfile = Path.join(dir, "pids")
    script = Path.expand("fixtures/agentlink_hold_fixture.py", __DIR__)
    File.chmod!(script, 0o755)

    File.write!(
      Path.join(root, "agent.link.json"),
      Jason.encode!(%{
        "name" => "fixture",
        "label" => "lifecycle",
        "program" => "fixture",
        "plane_url" => "ws://127.0.0.1:9/agent",
        "command" => System.find_executable("python3"),
        "args" => [script, pidfile, "quiet"]
      })
    )

    pidfile
  end

  defp write_closer!(dir) do
    path = Path.join(dir, "close_stdin.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import os, sys
    os.close(0)
    os.execv(sys.argv[1], sys.argv[1:])
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp await_listen!(port, port_num, log) do
    receive do
      {^port, {:data, data}} ->
        await_listen!(port, port_num, log <> data)

      {^port, {:exit_status, status}} ->
        flunk("release exited #{status} before listening\n#{shown(log)}")
    after
      0 ->
        if accept?(port_num), do: log, else: await_listen!(port, port_num, log)
    end
  end

  defp await_hold!(port, pidfile, log) do
    receive do
      {^port, {:data, data}} ->
        await_hold!(port, pidfile, log <> data)

      {^port, {:exit_status, status}} ->
        flunk("release exited #{status} before the hold fixture reported\n#{shown(log)}")
    after
      0 ->
        case File.read(pidfile) do
          {:ok, line} ->
            case Regex.run(~r/ready (\d+) (\d+)/, line) do
              [_, parent, child] ->
                {String.to_integer(parent), String.to_integer(child), log}

              _ ->
                await_hold!(port, pidfile, log)
            end

          _ ->
            await_hold!(port, pidfile, log)
        end
    end
  end

  defp await_running!(bin, env, port, os_pid, log) do
    receive do
      {^port, {:data, data}} ->
        await_running!(bin, env, port, os_pid, log <> data)

      {^port, {:exit_status, status}} ->
        flunk("connect exited #{status} before pid\n#{shown(log)}")
    after
      0 ->
        case System.cmd(bin, ["pid"], env: env, stderr_to_stdout: true) do
          {output, 0} ->
            if printed_pid(output) == os_pid do
              log <> output
            else
              await_running!(bin, env, port, os_pid, log)
            end

          _ ->
            await_running!(bin, env, port, os_pid, log)
        end
    end
  end

  defp printed_pid(output) do
    case Regex.run(~r/(\d+)\s*$/, output) do
      [_, pid] -> String.to_integer(pid)
      _ -> nil
    end
  end

  defp await_status!(port, log) do
    receive do
      {^port, {:data, data}} -> await_status!(port, log <> data)
      {^port, {:exit_status, status}} -> status
    end
  end

  defp await_exit!(port, log) do
    receive do
      {^port, {:data, data}} -> await_exit!(port, log <> data)
      {^port, {:exit_status, status}} -> {status, log}
    end
  end

  defp await_closed!(port_num) do
    if accept?(port_num) do
      receive do
      after
        0 -> await_closed!(port_num)
      end
    else
      :ok
    end
  end

  defp accept?(port_num) do
    case :gen_tcp.connect({127, 0, 0, 1}, port_num, [:binary, active: false], 50) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp track!(pid, starttime) do
    on_exit(fn -> signal_if_same!(pid, starttime, "-KILL") end)
  end

  defp port_os_pid(port) do
    {:os_pid, pid} = Port.info(port, :os_pid)
    pid
  end

  defp starttime!(pid) do
    {:ok, stat} = File.read("/proc/#{pid}/stat")
    {:ok, %{starttime: starttime}} = AgentLink.OwnedStop.parse_stat(stat)
    starttime
  end

  defp signal_if_same!(pid, starttime, flag) do
    if pid > 1 and Integer.to_string(pid) != System.pid() and still?(pid, starttime) do
      System.cmd(System.find_executable("kill"), [flag, Integer.to_string(pid)],
        stderr_to_stdout: true
      )
    end

    :ok
  end

  defp still?(pid, starttime) do
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
    if still?(pid, starttime) do
      receive do
      after
        0 -> await_gone!(pid, starttime)
      end
    else
      :ok
    end
  end

  defp shown(log), do: String.replace(log, "sekret", "[token]")
end
