defmodule AgentLink.ReleaseLifecycleTest do
  @moduledoc """
  The plain Mix release from `mix release`.

  `mix test --only release` runs these tests. The default suite excludes
  `:release`. Each test sets `RELEASE_SYS_CONFIG` and `HOME`. `:cli` is
  `true`. `:agent_stop_timeout` in that config is `0`, so a hold fixture
  that ignores `SIGTERM` is `SIGKILL`ed without the default `5000` wait.
  The commands are `bin/agentlink`, `bin/agentlink plane`, `bin/agentlink relay`,
  and `bin/agentlink connect`. A process-group `SIGTERM` is sent only when
  the release pid is that group and the group is not this VM's group.
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
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    bin = Path.join(root, "_build/prod/rel/agentlink/bin/agentlink")
    script = File.read!(bin)
    assert script =~ "shift\n    start \"elixir\" --no-halt -- \"$@\""
    assert script =~ "*)\n    start \"elixir\" --no-halt -- \"$@\""
    bat = File.read!(bin <> ".bat")
    assert bat =~ ":cli\n"
    assert bat =~ "setlocal DisableDelayedExpansion"
    assert bat =~ "--vm-args \"%RELEASE_VM_ARGS%\" -- %*"
    %{bin: bin}
  end

  setup context do
    dir = Path.join(System.tmp_dir!(), "agentlink-rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "home"))
    File.mkdir_p!(Path.join(dir, "tmp"))
    on_exit(fn -> File.rm_rf!(dir) end)
    Map.put(context, :dir, dir)
  end

  test "no arguments keep a sys.config plane", %{bin: bin, dir: dir} do
    port_num = 18_461
    sys = write_sys!(dir, plane_config(port_num))
    {port, os_pid, started} = boot!(bin, [], env(dir, "lifeplane", sys))
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
      boot!(bin, ["plane", "--port", "#{port_num}"], env(dir, "lifeplaneargv", sys))

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
      boot!(bin, ["relay", "--token", "sekret"], env(dir, "liferelay", sys))

    {parent, child, log} = await_hold!(port, pidfile, "")
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    track!(parent, parent_started)
    track!(child, child_started)
    assert shown(log) =~ "The uplink will dial the plane_url"
    refute accept?(port_num)
    assert_reaper_file!(dir)
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 0
    await_gone!(parent, parent_started)
    await_gone!(child, child_started)
    await_gone!(os_pid, started)
    refute_reaper_files!(dir)
    refute accept?(port_num)
  end

  test "no arguments run all and SIGTERM reaps the hold fixture", %{bin: bin, dir: dir} do
    port_num = 18_464
    pidfile = hold_link!(dir)
    sys = write_sys!(dir, all_config(port_num))
    {port, os_pid, started} = boot!(bin, [], env(dir, "lifeall", sys))

    log =
      await_listen!(port, port_num, "", "The agent relay on this machine is starting.")

    {parent, child, log} = await_hold!(port, pidfile, log)
    parent_started = starttime!(parent)
    child_started = starttime!(child)
    track!(parent, parent_started)
    track!(child, child_started)
    assert shown(log) =~ "The agent relay on this machine is starting."
    assert_reaper_file!(dir)
    signal_if_same!(os_pid, started, "-TERM")
    assert await_status!(port, log) == 0
    await_closed!(port_num)
    await_gone!(parent, parent_started)
    await_gone!(child, child_started)
    refute_reaper_files!(dir)
  end

  test "bin/agentlink stop shuts a plane down", %{bin: bin, dir: dir} do
    port_num = 18_465
    sys = write_sys!(dir, plane_config(port_num))
    env = env(dir, "lifestop", sys)
    {port, _os_pid, _started} = boot!(bin, ["plane"], env)
    log = await_listen!(port, port_num, "")
    {output, status} = System.cmd(bin, ["stop"], env: env, stderr_to_stdout: true)
    assert status == 0, shown(output)
    assert await_status!(port, log <> output) == 0
    await_closed!(port_num)
  end

  test "connect with stdin closed exits 0", %{bin: bin, dir: dir} do
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
    for n <- 1..4 do
      sys = write_sys!(dir, connect_config(), :notice)
      env = env(dir, "lifeconnect#{n}", sys)

      {port, os_pid, started} =
        boot!(
          bin,
          ["connect", "--plane", "ws://127.0.0.1:9/acp", "--token", "sekret"],
          env
        )

      log = await_running!(bin, env, port, os_pid, "")
      signal_if_same!(os_pid, started, "-TERM")
      {status, logged} = await_exit!(port, log)
      assert status == 1, shown(logged)
      assert shown(logged) =~ "SIGTERM received"
      await_gone!(os_pid, started)
    end
  end

  test "process-group SIGTERM stops plane, relay, all, and connect", %{bin: bin, dir: dir} do
    plane_group!(bin, dir)
    relay_group!(bin, dir)
    all_group!(bin, dir)
    connect_group!(bin, dir)
  end

  defp plane_group!(bin, dir) do
    port_num = 18_471
    sys = write_sys!(dir, plane_config(port_num))

    {port, leader, leader_started, child, child_started} =
      boot_group!(bin, [], env(dir, "lifeplanegrp", sys))

    log = await_listen!(port, port_num, "")
    signal_group!(child, child_started)
    assert await_status!(port, log) == 0
    await_closed!(port_num)
    await_gone!(child, child_started)
    await_gone!(leader, leader_started)
  end

  defp relay_group!(bin, dir) do
    pidfile = hold_link!(dir)
    File.rm(pidfile)
    sys = write_sys!(dir, plane_config(18_472))

    {port, leader, leader_started, child, child_started} =
      boot_group!(bin, ["relay", "--token", "sekret"], env(dir, "liferelaygrp", sys))

    {parent, held, log} = await_hold!(port, pidfile, "")
    parent_started = starttime!(parent)
    held_started = starttime!(held)
    track!(parent, parent_started)
    track!(held, held_started)
    assert_reaper_file!(dir)
    signal_group!(child, child_started)
    assert await_status!(port, log) == 0
    await_gone!(parent, parent_started)
    await_gone!(held, held_started)
    await_gone!(child, child_started)
    await_gone!(leader, leader_started)
    refute_reaper_files!(dir)
  end

  defp all_group!(bin, dir) do
    port_num = 18_473
    pidfile = hold_link!(dir)
    File.rm(pidfile)
    sys = write_sys!(dir, all_config(port_num))

    {port, leader, leader_started, child, child_started} =
      boot_group!(bin, [], env(dir, "lifeallgrp", sys))

    log = await_listen!(port, port_num, "", "The agent relay on this machine is starting.")
    {parent, held, log} = await_hold!(port, pidfile, log)
    parent_started = starttime!(parent)
    held_started = starttime!(held)
    track!(parent, parent_started)
    track!(held, held_started)
    assert_reaper_file!(dir)
    signal_group!(child, child_started)
    assert await_status!(port, log) == 0
    await_closed!(port_num)
    await_gone!(parent, parent_started)
    await_gone!(held, held_started)
    await_gone!(child, child_started)
    await_gone!(leader, leader_started)
    refute_reaper_files!(dir)
  end

  defp connect_group!(bin, dir) do
    sys = write_sys!(dir, connect_config(), :notice)
    env = env(dir, "lifeconnectgrp", sys)

    {port, leader, leader_started, child, child_started} =
      boot_group!(
        bin,
        ["connect", "--plane", "ws://127.0.0.1:9/acp", "--token", "sekret"],
        env
      )

    log = await_running!(bin, env, port, child, "")
    signal_group!(child, child_started)
    {status, logged} = await_exit!(port, log)
    assert status == 1, shown(logged)
    assert shown(logged) =~ "SIGTERM received"
    await_gone!(child, child_started)
    await_gone!(leader, leader_started)
  end

  defp boot!(bin, args, env) do
    boot_program!(System.find_executable("stdbuf"), ["-oL", "-eL", bin | args], env)
  end

  defp boot_group!(bin, args, env) do
    setsid = System.find_executable("setsid")
    stdbuf = System.find_executable("stdbuf")

    {port, leader, leader_started} =
      boot_program!(setsid, ["-w", "--", stdbuf, "-oL", "-eL", bin | args], env)

    {child, child_started} =
      await_child!(leader, leader_started, System.monotonic_time(:millisecond) + 10_000)

    track!(child, child_started)
    {port, leader, leader_started, child, child_started}
  end

  defp await_child!(parent, parent_started, deadline) do
    receive do
    after
      0 ->
        case group_leaders(parent) do
          [pid] ->
            {pid, starttime!(pid)}

          [] ->
            cond do
              not still?(parent, parent_started) ->
                flunk("setsid #{parent} exited before the release started")

              System.monotonic_time(:millisecond) > deadline ->
                flunk("setsid #{parent} did not start a release")

              true ->
                await_child!(parent, parent_started, deadline)
            end

          pids ->
            flunk("setsid #{parent} started more than one group leader: #{inspect(pids)}")
        end
    end
  end

  defp group_leaders(parent) do
    case File.ls("/proc") do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          with {pid, ""} <- Integer.parse(name),
               {:ok, stat} <- File.read("/proc/#{pid}/stat"),
               {:ok, %{ppid: ^parent, state: state}} <- AgentLink.OwnedStop.parse_stat(stat),
               true <- state != "Z",
               pgid when pgid == pid <- pgrp(pid) do
            [pid]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp signal_group!(pid, starttime) do
    pgid = pgrp(pid)
    mine = pgrp(String.to_integer(System.pid()))

    cond do
      not still?(pid, starttime) ->
        flunk("release #{pid} exited before the group signal")

      pgid != pid ->
        flunk(
          "release #{pid} is in group #{inspect(pgid)}, so the test will not signal that group"
        )

      pgid == mine ->
        flunk("release #{pid} shares this VM's process group")

      true ->
        System.cmd(
          System.find_executable("kill"),
          ["-s", "TERM", "--", Integer.to_string(-pgid)],
          stderr_to_stdout: true
        )

        :ok
    end
  end

  defp pgrp(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        {pos, _} = List.last(:binary.matches(stat, ")"))
        rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
        fields = String.split(rest, " ", trim: true)

        case Integer.parse(Enum.at(fields, 2)) do
          {pgid, ""} -> pgid
          _ -> nil
        end

      _ ->
        nil
    end
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
      {"RELEASE_DISTRIBUTION", "sname"},
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

  defp write_sys!(dir, pairs, level \\ :warning) do
    path = Path.join(dir, "sys")

    File.write!(
      path <> ".config",
      "%% coding: utf-8\n%% RUNTIME_CONFIG=false\n[{agent_link,[#{pairs}]},{logger,[{level,#{level}}]}].\n"
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

  @listen_deadline_ms 30_000
  @listen_banner "Waiting for the uplink to connect."

  defp await_listen!(port, port_num, log, marker \\ @listen_banner) do
    await_listen!(port, port_num, log, marker, System.monotonic_time(:millisecond))
  end

  defp await_listen!(port, port_num, log, marker, started) do
    receive do
      {^port, {:data, data}} ->
        await_listen!(port, port_num, log <> data, marker, started)

      {^port, {:exit_status, status}} ->
        flunk("release exited #{status} before listening\n#{shown(log)}")
    after
      0 ->
        cond do
          accept?(port_num) and String.contains?(log, marker) ->
            log

          System.monotonic_time(:millisecond) - started >= @listen_deadline_ms ->
            flunk(
              "127.0.0.1:#{port_num} did not log #{marker} within #{@listen_deadline_ms}ms\n#{shown(log)}"
            )

          true ->
            await_listen!(port, port_num, log, marker, started)
        end
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

  defp assert_reaper_file!(dir) do
    assert Enum.any?(reaper_names(dir), &String.ends_with?(&1, ".bin"))
  end

  defp refute_reaper_files!(dir) do
    assert reaper_names(dir) == []
  end

  defp reaper_names(dir) do
    dir
    |> Path.join("tmp")
    |> File.ls!()
    |> Enum.filter(&String.contains?(&1, "agent-reaper-"))
  end
end
