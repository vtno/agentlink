defmodule AgentLink.Relay.AgentTest.DownTransport do
  @moduledoc false
  def start_link(_opts), do: {:error, :transport_down}
end

defmodule AgentLink.Relay.AgentTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:agent_link, :agent_listener, self())
    previous = Application.get_env(:agent_link, :link_path)

    path =
      Path.join(System.tmp_dir!(), "agentlink-relay-#{System.unique_integer([:positive])}.json")

    File.write!(path, link_body())

    Application.put_env(:agent_link, :link_path, path)

    on_exit(fn ->
      Application.delete_env(:agent_link, :agent_listener)

      if previous,
        do: Application.put_env(:agent_link, :link_path, previous),
        else: Application.delete_env(:agent_link, :link_path)

      File.rm(path)
      stop(AgentLink.Relay.Agent)
      stop(AgentLink.Uplink)
    end)

    :ok
  end

  test "shutdown outlasts two agent stop waits" do
    previous = Application.get_env(:agent_link, :agent_stop_timeout)
    Application.put_env(:agent_link, :agent_stop_timeout, 40)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :agent_stop_timeout, previous),
        else: Application.delete_env(:agent_link, :agent_stop_timeout)
    end)

    assert AgentLink.Relay.Agent.child_spec([]).shutdown == 1_080
  end

  test "send_message is down when the agent relay is not running" do
    assert AgentLink.Relay.Agent.send_message(%{"method" => "ping"}) == :down
  end

  test "stdout lines reach the uplink, and a partial line waits" do
    agent = start_relay!()
    AgentLink.FakeAgent.emit(agent, ~s({"method":"hi"}))
    refute_receive {:agent_write, _}, 30
    AgentLink.FakeAgent.emit(agent, "\n")
    assert wait_for(fn -> %{"method" => "hi"} in uplink_outbox() end)

    AgentLink.FakeAgent.emit(agent, "not-json\n")
    Process.sleep(30)
    refute Enum.any?(uplink_outbox(), &(&1 == "not-json"))
  end

  test "a dropped stdout line is logged as a bounded prefix" do
    agent = start_relay!()
    prefix = String.duplicate("x", 80)
    tail = "TAIL-NOT-LOGGED"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        AgentLink.FakeAgent.emit(agent, prefix <> tail <> "\n")
        :sys.get_state(agent)
        :sys.get_state(AgentLink.Relay.Agent)
      end)

    assert log =~ "agent relay dropped non-json stdout"
    assert log =~ prefix
    refute log =~ tail

    invalid = <<0x20, 0xFF>>

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        AgentLink.FakeAgent.emit(agent, invalid <> "\n")
        :sys.get_state(agent)
        :sys.get_state(AgentLink.Relay.Agent)
      end)

    assert log =~ "agent relay dropped non-json stdout"
    assert log =~ inspect(invalid)
    assert Process.alive?(Process.whereis(AgentLink.Relay.Agent))
  end

  test "a message from the plane is written to the agent" do
    _agent = start_relay!()
    send(AgentLink.Relay.Agent, {:from_plane, %{"method" => "ping"}})
    assert_receive {:agent_write, line}
    assert String.ends_with?(line, "\n")
    assert %{"method" => "ping"} = Jason.decode!(String.trim(line))
  end

  for method <- ["session/new", "session/load"] do
    for {description, cwd_params} <- [
          {"missing", %{}},
          {"null", %{"cwd" => nil}},
          {"empty", %{"cwd" => ""}}
        ] do
      test "#{method} fills #{description} cwd with the relay workspace" do
        _agent = start_relay!()

        params =
          Map.merge(
            %{"sessionId" => "session-1", "mcpServers" => []},
            unquote(Macro.escape(cwd_params))
          )

        message = %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => unquote(method),
          "params" => params
        }

        expected = put_in(message, ["params", "cwd"], AgentLink.Paths.workdir())

        send(AgentLink.Relay.Agent, {:from_plane, message})

        assert_receive {:agent_write, line}
        assert Jason.decode!(line) == expected
      end
    end

    test "#{method} preserves an explicit cwd" do
      _agent = start_relay!()

      message = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => unquote(method),
        "params" => %{"cwd" => "/some/explicit/workspace", "mcpServers" => []}
      }

      send(AgentLink.Relay.Agent, {:from_plane, message})

      assert_receive {:agent_write, line}
      assert Jason.decode!(line) == message
    end
  end

  test "send_message defaults cwd when session/new has no params" do
    _agent = start_relay!()
    message = %{"jsonrpc" => "2.0", "id" => 7, "method" => "session/new"}

    assert :ok = AgentLink.Relay.Agent.send_message(message)

    assert_receive {:agent_write, line}

    assert Jason.decode!(line) ==
             Map.put(message, "params", %{"cwd" => AgentLink.Paths.workdir()})
  end

  test "other methods keep an empty cwd unchanged" do
    _agent = start_relay!()
    message = %{"method" => "session/prompt", "params" => %{"cwd" => ""}}

    send(AgentLink.Relay.Agent, {:from_plane, message})

    assert_receive {:agent_write, line}
    assert Jason.decode!(line) == message
  end

  test "a closed agent stops the agent relay" do
    agent = start_relay!()
    relay = Process.whereis(AgentLink.Relay.Agent)
    ref = Process.monitor(relay)
    AgentLink.FakeAgent.refuse(agent)
    AgentLink.Relay.Agent.send_message(%{"method" => "x"})
    assert_receive {:DOWN, ^ref, :process, ^relay, :port_closed}
  end

  test "an exit status stops the agent relay" do
    agent = start_relay!()
    relay = Process.whereis(AgentLink.Relay.Agent)
    ref = Process.monitor(relay)
    AgentLink.FakeAgent.exit_status(agent, 3)
    assert_receive {:DOWN, ^ref, :process, ^relay, {:agent_exit, 3}}
  end

  test "the agent process dying stops the agent relay" do
    agent = start_relay!()
    relay = Process.whereis(AgentLink.Relay.Agent)
    ref = Process.monitor(relay)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^relay, {:agent_exit, :killed}}
  end

  test "a missing link file stops the agent relay before the agent opens" do
    Process.flag(:trap_exit, true)

    Application.put_env(
      :agent_link,
      :link_path,
      "/tmp/agentlink-relay-missing-#{System.unique_integer([:positive])}.json"
    )

    assert {:error, {:shutdown, message}} = AgentLink.Relay.Agent.start_link([])
    assert message =~ "No link file"
    refute_received {:agent_opened, _agent, _launch, _cwd}
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "an invalid launch stops the agent relay before the agent opens" do
    Process.flag(:trap_exit, true)
    File.write!(Application.fetch_env!(:agent_link, :link_path), ~s({"name":"opencode"}))

    assert {:error, {:shutdown, message}} = AgentLink.Relay.Agent.start_link([])
    assert message =~ "must include a command"
    refute_received {:agent_opened, _agent, _launch, _cwd}
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "an open error stops the agent relay and does not leave a port" do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:agent_link, :agent_module)
    Application.put_env(:agent_link, :agent_module, AgentLink.Agent.Process)

    on_exit(fn -> AgentLink.TestHelpers.restore(:agent_module, previous) end)

    File.write!(
      Application.fetch_env!(:agent_link, :link_path),
      ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent","command":"agentlink-no-such-bin","args":[]})
    )

    assert {:error, {:shutdown, message}} = AgentLink.Relay.Agent.start_link([])
    assert message =~ "could not find agentlink-no-such-bin"
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "the relay's initial uplink uses the link from the one launch read" do
    assert {:unix, _} = :os.type()
    dir = Path.join(System.tmp_dir!(), "agentlink-fifo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fifo = Path.join(dir, "agent.link.json")
    {"", 0} = System.cmd("mkfifo", [fifo])
    previous = Application.get_env(:agent_link, :link_path)
    Application.put_env(:agent_link, :link_path, fifo)

    writer =
      spawn(fn ->
        # `File.read/1` blocks in the file server until this writer closes.
        # `:prim_file` writes without that server, so the read can finish.
        # The second open waits until that read has returned. Opening it
        # earlier can append `second` onto the bytes of the first read.
        serve = fn body ->
          {:ok, fd} = :prim_file.open(String.to_charlist(fifo), [:write, :binary])
          :ok = :prim_file.write(fd, body)
          :ok = :prim_file.close(fd)
        end

        serve.(snapshot_body("first"))

        receive do
          :second -> serve.(snapshot_body("second"))
        end
      end)

    on_exit(fn ->
      Process.exit(writer, :kill)
      AgentLink.TestHelpers.restore(:link_path, previous)
      stop(AgentLink.Relay.Agent)
      stop(AgentLink.Uplink)
      File.rm_rf(dir)
    end)

    start_supervised!(%{
      id: AgentLink.Relay.Agent,
      start:
        {AgentLink.Relay.Agent, :start_link,
         [
           [
             transport: AgentLink.FakeTransport,
             transport_opts: [backoff: 60_000],
             watch_interval: nil
           ]
         ]},
      restart: :temporary
    })

    assert_receive {:agent_opened, _agent, launch, _cwd}
    assert launch == %AgentLink.Agent.Launch{command: "agentlink-fake", args: ["acp"]}
    %{transport_pid: transport} = :sys.get_state(AgentLink.Uplink)
    assert [hello] = AgentLink.FakeTransport.sent(transport)
    assert hello["params"]["name"] == "first"
    assert hello["params"]["label"] == "first"
    assert hello["params"]["program"] == "metadata"
    send(writer, :second)
    assert :ok = await_blocked_open!(writer)
  end

  test "an uplink start failure closes the agent and returns that reason" do
    Process.flag(:trap_exit, true)

    assert {:error, :transport_down} =
             AgentLink.Relay.Agent.start_link(transport: AgentLink.Relay.AgentTest.DownTransport)

    assert_receive {:agent_opened, agent, %AgentLink.Agent.Launch{}, _cwd}
    refute Process.alive?(agent)
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "a link failure stops the agent relay instead of starting another uplink" do
    _agent = start_relay!()
    relay = Process.whereis(AgentLink.Relay.Agent)
    uplink = Process.whereis(AgentLink.Uplink)
    ref = Process.monitor(relay)
    send(relay, {:EXIT, uplink, {:shutdown, "No link file at /tmp/gone.json"}})
    assert_receive {:DOWN, ^ref, :process, ^relay, {:shutdown, "No link file" <> _}}
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "an uplink crash starts another uplink" do
    _agent = start_relay!()
    first = Process.whereis(AgentLink.Uplink)
    Process.exit(first, :kill)
    Process.sleep(50)
    second = Process.whereis(AgentLink.Uplink)
    assert is_pid(second)
    assert second != first
    assert Process.alive?(Process.whereis(AgentLink.Relay.Agent))
  end

  test "stopping the agent relay closes the agent" do
    agent = start_relay!()
    ref = Process.monitor(agent)
    GenServer.stop(AgentLink.Relay.Agent)
    assert_receive {:DOWN, ^ref, :process, ^agent, _}
  end

  test "an unknown message is ignored" do
    _agent = start_relay!()
    send(AgentLink.Relay.Agent, :nope)
    Process.sleep(20)
    assert Process.alive?(Process.whereis(AgentLink.Relay.Agent))
  end

  defp start_relay! do
    start_supervised!(%{
      id: AgentLink.Relay.Agent,
      start: {AgentLink.Relay.Agent, :start_link, [[]]},
      restart: :temporary
    })

    assert_receive {:agent_opened, agent, launch, cwd}
    assert cwd == "/tmp/agentlink-test-workdir"
    assert launch == %AgentLink.Agent.Launch{command: "agentlink-fake", args: ["acp"]}
    agent
  end

  defp snapshot_body(name) do
    Jason.encode!(%{
      "name" => name,
      "label" => name,
      "program" => "metadata",
      "plane_url" => "ws://127.0.0.1:1/agent",
      "command" => "agentlink-fake",
      "args" => ["acp"]
    })
  end

  defp link_body do
    ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent","command":"agentlink-fake","args":["acp"]})
  end

  defp wait_for(fun) do
    Enum.reduce_while(1..20, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(10) && {:cont, false}
    end)
  end

  defp uplink_outbox do
    %{transport_pid: pid} = :sys.get_state(AgentLink.Uplink)
    :sys.get_state(pid).outbox
  end

  defp await_blocked_open!(writer) do
    receive do
    after
      0 ->
        case Process.info(writer, :current_stacktrace) do
          {:current_stacktrace, stack} ->
            if Enum.any?(stack, &match?({:prim_file, :open, 2, _}, &1)) do
              :ok
            else
              await_blocked_open!(writer)
            end

          nil ->
            flunk("the second link read consumed the next payload")
        end
    end
  end

  defp stop(name) do
    if pid = Process.whereis(name), do: Process.exit(pid, :kill)
  end
end
