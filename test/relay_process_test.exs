defmodule AgentLink.Relay.ProcessTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AgentLink.FakeTransport

  @plain ["spaced arg", ""]
  @replaced ["replaced", ""]

  setup_all do
    beam_dir =
      Path.join(
        System.tmp_dir!(),
        "agentlink-relay-fixture-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(beam_dir)
    compile_fixture!(beam_dir)
    exe = otp_executable()
    assert File.regular?(exe)
    on_exit(fn -> File.rm_rf!(beam_dir) end)
    %{beam_dir: beam_dir, exe: exe}
  end

  setup %{beam_dir: beam_dir, exe: exe} do
    previous = %{
      agent_module: Application.get_env(:agent_link, :agent_module),
      link_path: Application.get_env(:agent_link, :link_path),
      workdir: Application.get_env(:agent_link, :workdir),
      probe: System.get_env("AGENTLINK_PROCESS_PROBE"),
      autoupdate: System.get_env("OPENCODE_DISABLE_AUTOUPDATE"),
      stamp: System.get_env("AGENTLINK_FIXTURE_STAMP"),
      ready: System.get_env("AGENTLINK_FIXTURE_READY"),
      stderr_path: System.get_env("AGENTLINK_STDERR_PATH"),
      stderr_token: System.get_env("AGENTLINK_STDERR_TOKEN"),
      reaper_dir: Application.get_env(:agent_link, :reaper_dir)
    }

    reaper_dir =
      Path.join(System.tmp_dir!(), "agentlink-reaper-#{System.unique_integer([:positive])}")

    File.mkdir_p!(reaper_dir)
    Application.put_env(:agent_link, :reaper_dir, reaper_dir)

    root = Path.join(System.tmp_dir!(), "agentlink-wired-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workdir = Path.join(root, "workspace")
    link = Path.join(root, "agent.link.json")
    ready = Path.join(root, "ready")
    stderr_path = Path.join(root, "stderr-token")
    stamp = Path.join(root, "stamp")

    Application.put_env(:agent_link, :agent_module, AgentLink.Agent.Process)
    Application.put_env(:agent_link, :link_path, link)
    Application.put_env(:agent_link, :workdir, workdir)
    System.put_env("AGENTLINK_PROCESS_PROBE", "probe-token")
    System.delete_env("OPENCODE_DISABLE_AUTOUPDATE")
    System.put_env("AGENTLINK_FIXTURE_STAMP", stamp)
    System.put_env("AGENTLINK_FIXTURE_READY", ready)
    System.put_env("AGENTLINK_STDERR_PATH", stderr_path)
    System.put_env("AGENTLINK_STDERR_TOKEN", "agentlink-stderr-token")

    {:ok, tracker} = Agent.start(fn -> %{sup: nil, pids: []} end)

    on_exit(fn ->
      %{sup: sup, pids: pids} = Agent.get(tracker, & &1)
      stop_supervisor(sup)
      Enum.each(pids, &reap!/1)
      Agent.stop(tracker)
      restore_env(previous)
      File.rm_rf(root)
      if pid = Process.whereis(AgentLink.Relay.Agent), do: Process.exit(pid, :kill)
      if pid = Process.whereis(AgentLink.Uplink), do: Process.exit(pid, :kill)
      if pid = Process.whereis(AgentLink.Agent.Reaper), do: Process.exit(pid, :kill)
    end)

    %{
      workdir: workdir,
      link: link,
      ready: ready,
      stderr_path: stderr_path,
      beam_dir: beam_dir,
      exe: exe,
      tracker: tracker
    }
  end

  test "stdio bytes travel both ways, and a split stdout line waits for its newline", %{
    link: link,
    exe: exe,
    beam_dir: beam_dir,
    ready: ready,
    tracker: tracker
  } do
    write_link!(link, exe, beam_dir, @plain)
    start_relay!(tracker)
    message = %{"method" => "session/prompt", "params" => %{"text" => "ping-body"}}
    deliver!(message)
    assert message in await_sent(fn messages -> message in messages end)

    File.rm(ready)
    deliver!(%{"op" => "split"})
    await_file!(ready, "split")
    await_buffer!(~s({"method":"hi"}))
    refute Enum.any?(sent(), &(&1["method"] == "hi"))

    File.rm(ready)
    deliver!(%{"op" => "newline"})
    await_file!(ready, "newline")

    assert Enum.any?(
             await_sent(fn messages -> Enum.any?(messages, &(&1["method"] == "hi")) end),
             &(&1["method"] == "hi")
           )

    track_current!(tracker)
  end

  test "the fixture reports argv, cwd, inherited env, and stderr separate from stdout", %{
    link: link,
    exe: exe,
    beam_dir: beam_dir,
    workdir: workdir,
    stderr_path: stderr_path,
    tracker: tracker
  } do
    write_link!(link, exe, beam_dir, @plain)
    start_relay!(tracker)
    probe = await_probe!()
    os_pid = track!(tracker, probe)
    assert probe["args"] == @plain
    assert probe["cwd"] == workdir
    assert probe["probe"] == "probe-token"
    assert probe["autoupdate"] == nil
    assert os_pid == port_os_pid()

    deliver!(%{"op" => "stderr"})
    assert %{"stderr" => "ok"} = await_fixture!("stderr")
    assert File.read!(stderr_path) == "agentlink-stderr-token"

    refute Enum.any?(sent(), fn message ->
             Jason.encode!(message) =~ "agentlink-stderr-token"
           end)
  end

  test "a transport reconnect keeps the child, and the next restart reads the new launch", %{
    link: link,
    exe: exe,
    beam_dir: beam_dir,
    tracker: tracker
  } do
    write_link!(link, exe, beam_dir, @plain, %{"plane_url" => "ws://127.0.0.1:1/agent"})
    start_relay!(tracker)
    first = await_probe!()
    os_pid = track!(tracker, first)
    assert first["args"] == @plain
    assert os_pid == port_os_pid()
    uplink = Process.whereis(AgentLink.Uplink)
    assert length(hellos()) == 1

    :ok = FakeTransport.disconnect(transport(), 1001, "going away")
    :sys.get_state(uplink)
    assert port_os_pid() == os_pid
    assert os_alive?(os_pid)
    assert length(hellos()) == 1

    assert :closed =
             FakeTransport.deliver(transport(), %{
               "method" => "session/prompt",
               "params" => %{"text" => "while-down"}
             })

    :ok = FakeTransport.complete_dial(transport())
    :sys.get_state(transport())
    assert length(hellos()) == 2
    assert :sys.get_state(transport()).url == "ws://127.0.0.1:1/agent"
    assert port_os_pid() == os_pid
    assert os_alive?(os_pid)

    resumed = %{"method" => "session/prompt", "params" => %{"text" => "after-reconnect"}}
    deliver!(resumed)
    assert resumed in await_sent(fn messages -> resumed in messages end)
    refute Enum.any?(sent(), &(get_in(&1, ["params", "text"]) == "while-down"))
    assert port_os_pid() == os_pid

    write_link!(link, exe, beam_dir, @plain, %{"plane_url" => "ws://127.0.0.1:9/agent"})
    watch!(uplink)
    assert :sys.get_state(transport()).url == "ws://127.0.0.1:9/agent"
    assert length(hellos()) == 3
    assert port_os_pid() == os_pid
    again = await_probe!()
    assert again["os_pid"] == first["os_pid"]
    assert again["args"] == @plain

    write_link!(link, exe, beam_dir, @replaced, %{"plane_url" => "ws://127.0.0.1:9/agent"})
    watch!(uplink)
    assert length(hellos()) == 3
    assert :sys.get_state(transport()).url == "ws://127.0.0.1:9/agent"
    assert port_os_pid() == os_pid
    held = await_probe!()
    assert held["os_pid"] == first["os_pid"]
    assert held["args"] == @plain

    relay = Process.whereis(AgentLink.Relay.Agent)
    deliver!(%{"op" => "exit"})
    await_new_relay!(relay)
    refute os_alive?(os_pid)
    restarted = await_probe!()
    new_pid = track!(tracker, restarted)
    assert new_pid != os_pid
    assert restarted["args"] == @replaced
    assert new_pid == port_os_pid()
  end

  defp start_relay!(tracker) do
    {:ok, sup} =
      Supervisor.start_link(
        [
          AgentLink.Agent.Reaper,
          %{
            id: AgentLink.Relay.Agent,
            start: {AgentLink.Relay.Agent, :start_link, [relay_opts()]},
            restart: :permanent
          }
        ],
        strategy: :one_for_one,
        max_restarts: 5,
        max_seconds: 20
      )

    Process.unlink(sup)
    Agent.update(tracker, &%{&1 | sup: sup})
    _relay = await_new_relay!(nil)
    sup
  end

  defp relay_opts do
    [transport: FakeTransport, transport_opts: [backoff: 60_000], watch_interval: nil]
  end

  defp write_link!(path, exe, beam_dir, plain, attrs \\ %{}) do
    args = [
      "-noshell",
      "-pa",
      beam_dir,
      "-run",
      "agentlink_process_fixture",
      "start",
      "--" | plain
    ]

    body =
      Map.merge(
        %{
          "name" => "opencode",
          "label" => "this machine",
          "program" => "opencode",
          "plane_url" => "ws://127.0.0.1:1/agent",
          "command" => exe,
          "args" => args
        },
        attrs
      )

    File.write!(path, Jason.encode!(body))
  end

  defp deliver!(message) do
    :ok = FakeTransport.deliver(transport(), message)
    :sys.get_state(Process.whereis(AgentLink.Uplink))
    :sys.get_state(Process.whereis(AgentLink.Relay.Agent))
  end

  defp watch!(uplink) do
    send(uplink, :watch)
    :sys.get_state(uplink)
    :sys.get_state(uplink)
    sent()
  end

  defp await_probe! do
    deliver!(%{"op" => "probe"})

    await_sent(fn messages ->
      Enum.any?(messages, &probe?/1)
    end)

    sent()
    |> Enum.filter(&probe?/1)
    |> List.last()
  end

  defp await_fixture!(key) do
    await_sent(fn messages ->
      Enum.any?(messages, &(is_map(&1) and Map.has_key?(&1, key)))
    end)

    sent()
    |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, key)))
    |> List.last()
  end

  defp probe?(message) do
    message["method"] == "agentlink.fixture" and is_binary(message["os_pid"])
  end

  defp await_sent(fun) do
    receive do
    after
      0 ->
        messages = sent()
        if fun.(messages), do: messages, else: await_sent(fun)
    end
  end

  defp sent do
    uplink = Process.whereis(AgentLink.Uplink)
    :sys.get_state(uplink)
    FakeTransport.sent(transport())
  end

  defp hellos do
    Enum.filter(sent(), &(&1["method"] == "agentlink.uplink"))
  end

  defp transport do
    :sys.get_state(Process.whereis(AgentLink.Uplink)).transport_pid
  end

  defp await_buffer!(text) do
    receive do
    after
      0 ->
        %{buffer: buffer} = :sys.get_state(Process.whereis(AgentLink.Relay.Agent))
        if String.contains?(buffer, text), do: :ok, else: await_buffer!(text)
    end
  end

  defp await_file!(path, text) do
    receive do
    after
      0 ->
        case File.read(path) do
          {:ok, ^text} -> :ok
          _ -> await_file!(path, text)
        end
    end
  end

  defp await_new_relay!(old) do
    receive do
    after
      0 ->
        case Process.whereis(AgentLink.Relay.Agent) do
          pid when is_pid(pid) and pid != old ->
            if Process.alive?(pid), do: pid, else: await_new_relay!(old)

          _ ->
            await_new_relay!(old)
        end
    end
  end

  defp track!(tracker, probe) do
    os_pid = String.to_integer(probe["os_pid"])
    Agent.update(tracker, fn state -> %{state | pids: [os_pid | state.pids]} end)
    os_pid
  end

  defp track_current!(tracker) do
    if Process.whereis(AgentLink.Relay.Agent) do
      track!(tracker, %{"os_pid" => Integer.to_string(port_os_pid())})
    end
  end

  defp port_os_pid do
    %{agent: port} = :sys.get_state(Process.whereis(AgentLink.Relay.Agent))
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  defp stop_supervisor(nil), do: :ok

  defp stop_supervisor(sup) do
    if Process.alive?(sup) do
      try do
        Supervisor.stop(sup)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp reap!(os_pid) do
    receive do
    after
      0 ->
        if os_alive?(os_pid), do: reap!(os_pid), else: :ok
    end
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

  defp restore_env(previous) do
    AgentLink.TestHelpers.restore(:agent_module, previous.agent_module)
    AgentLink.TestHelpers.restore(:link_path, previous.link_path)
    AgentLink.TestHelpers.restore(:workdir, previous.workdir)
    AgentLink.TestHelpers.restore(:reaper_dir, previous.reaper_dir)
    restore_system("AGENTLINK_PROCESS_PROBE", previous.probe)
    restore_system("OPENCODE_DISABLE_AUTOUPDATE", previous.autoupdate)
    restore_system("AGENTLINK_FIXTURE_STAMP", previous.stamp)
    restore_system("AGENTLINK_FIXTURE_READY", previous.ready)
    restore_system("AGENTLINK_STDERR_PATH", previous.stderr_path)
    restore_system("AGENTLINK_STDERR_TOKEN", previous.stderr_token)
  end

  defp restore_system(key, nil), do: System.delete_env(key)
  defp restore_system(key, value), do: System.put_env(key, value)

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
end
