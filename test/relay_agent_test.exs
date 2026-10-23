defmodule Pont.Relay.AgentTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:pont, :agent_listener, self())
    previous = Application.get_env(:pont, :link_path)
    path = Path.join(System.tmp_dir!(), "pont-sidecar-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent"}))
    Application.put_env(:pont, :link_path, path)

    on_exit(fn ->
      Application.delete_env(:pont, :agent_listener)
      if previous, do: Application.put_env(:pont, :link_path, previous), else: Application.delete_env(:pont, :link_path)
      File.rm(path)
      stop(Pont.Relay.Agent)
      stop(Pont.Uplink)
    end)

    :ok
  end

  test "send_message is down when the agent relay is not running" do
    assert Pont.Relay.Agent.send_message(%{"method" => "ping"}) == :down
  end

  test "stdout lines reach the uplink, and a partial line waits" do
    agent = start_relay!()
    Pont.FakeAgent.emit(agent, ~s({"method":"hi"}))
    refute_receive {:agent_write, _}, 30
    Pont.FakeAgent.emit(agent, "\n")
    assert wait_for(fn -> %{"method" => "hi"} in uplink_outbox() end)

    Pont.FakeAgent.emit(agent, "not-json\n")
    Process.sleep(30)
    refute Enum.any?(uplink_outbox(), &(&1 == "not-json"))
  end

  test "a message from the plane is written to the agent" do
    _agent = start_relay!()
    send(Pont.Relay.Agent, {:from_plane, %{"method" => "ping"}})
    assert_receive {:agent_write, line}
    assert String.ends_with?(line, "\n")
    assert %{"method" => "ping"} = Jason.decode!(String.trim(line))
  end

  test "a closed agent stops the agent relay" do
    agent = start_relay!()
    sidecar = Process.whereis(Pont.Relay.Agent)
    ref = Process.monitor(sidecar)
    Pont.FakeAgent.refuse(agent)
    Pont.Relay.Agent.send_message(%{"method" => "x"})
    assert_receive {:DOWN, ^ref, :process, ^sidecar, :port_closed}
  end

  test "an exit status stops the agent relay" do
    agent = start_relay!()
    sidecar = Process.whereis(Pont.Relay.Agent)
    ref = Process.monitor(sidecar)
    Pont.FakeAgent.exit_status(agent, 3)
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:opencode_exit, 3}}
  end

  test "the agent process dying stops the agent relay" do
    agent = start_relay!()
    sidecar = Process.whereis(Pont.Relay.Agent)
    ref = Process.monitor(sidecar)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:opencode_exit, :killed}}
  end

  test "a missing link file stops the agent relay and closes the agent" do
    Process.flag(:trap_exit, true)
    Application.put_env(:pont, :link_path, "/tmp/pont-sidecar-missing-#{System.unique_integer([:positive])}.json")

    assert {:error, {:shutdown, message}} = Pont.Relay.Agent.start_link([])
    assert message =~ "No link file"
    assert_receive {:agent_opened, agent, _cwd}
    refute Process.alive?(agent)
    refute Process.whereis(Pont.Relay.Agent)
  end

  test "a link failure stops the agent relay instead of starting another uplink" do
    _agent = start_relay!()
    sidecar = Process.whereis(Pont.Relay.Agent)
    uplink = Process.whereis(Pont.Uplink)
    ref = Process.monitor(sidecar)
    send(sidecar, {:EXIT, uplink, {:shutdown, "No link file at /tmp/gone.json"}})
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:shutdown, "No link file" <> _}}
    refute Process.whereis(Pont.Relay.Agent)
  end

  test "an uplink crash starts another uplink" do
    _agent = start_relay!()
    first = Process.whereis(Pont.Uplink)
    Process.exit(first, :kill)
    Process.sleep(50)
    second = Process.whereis(Pont.Uplink)
    assert is_pid(second)
    assert second != first
    assert Process.alive?(Process.whereis(Pont.Relay.Agent))
  end

  test "stopping the agent relay closes the agent" do
    agent = start_relay!()
    ref = Process.monitor(agent)
    GenServer.stop(Pont.Relay.Agent)
    assert_receive {:DOWN, ^ref, :process, ^agent, _}
  end

  test "an unknown message is ignored" do
    _agent = start_relay!()
    send(Pont.Relay.Agent, :nope)
    Process.sleep(20)
    assert Process.alive?(Process.whereis(Pont.Relay.Agent))
  end

  defp start_relay! do
    start_supervised!(%{
      id: Pont.Relay.Agent,
      start: {Pont.Relay.Agent, :start_link, [[]]},
      restart: :temporary
    })

    assert_receive {:agent_opened, agent, cwd}
    assert cwd == "/tmp/pont-test-workdir"
    agent
  end

  defp wait_for(fun) do
    Enum.reduce_while(1..20, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(10) && {:cont, false}
    end)
  end

  defp uplink_outbox do
    :sys.get_state(Pont.Uplink).outbox
  end

  defp stop(name) do
    if pid = Process.whereis(name), do: Process.exit(pid, :kill)
  end
end
