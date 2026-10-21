defmodule Acp.SidecarTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:acp, :harness_listener, self())

    on_exit(fn ->
      Application.delete_env(:acp, :harness_listener)
      stop(Acp.Sidecar)
      stop(Acp.Uplink)
    end)

    :ok
  end

  test "send_message is down when the sidecar is not running" do
    assert Acp.Sidecar.send_message(%{"method" => "ping"}) == :down
  end

  test "stdout lines reach the uplink, and a partial line waits" do
    agent = start_sidecar!()
    Acp.FakeHarness.emit(agent, ~s({"method":"hi"}))
    refute_receive {:harness_write, _}, 30
    Acp.FakeHarness.emit(agent, "\n")
    assert wait_for(fn -> %{"method" => "hi"} in uplink_outbox() end)

    Acp.FakeHarness.emit(agent, "not-json\n")
    Process.sleep(30)
    refute Enum.any?(uplink_outbox(), &(&1 == "not-json"))
  end

  test "a message from the plane is written to the agent" do
    _agent = start_sidecar!()
    send(Acp.Sidecar, {:from_plane, %{"method" => "ping"}})
    assert_receive {:harness_write, line}
    assert String.ends_with?(line, "\n")
    assert %{"method" => "ping"} = Jason.decode!(String.trim(line))
  end

  test "a closed agent stops the sidecar" do
    agent = start_sidecar!()
    sidecar = Process.whereis(Acp.Sidecar)
    ref = Process.monitor(sidecar)
    Acp.FakeHarness.refuse(agent)
    Acp.Sidecar.send_message(%{"method" => "x"})
    assert_receive {:DOWN, ^ref, :process, ^sidecar, :port_closed}
  end

  test "an exit status stops the sidecar" do
    agent = start_sidecar!()
    sidecar = Process.whereis(Acp.Sidecar)
    ref = Process.monitor(sidecar)
    Acp.FakeHarness.exit_status(agent, 3)
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:opencode_exit, 3}}
  end

  test "the agent process dying stops the sidecar" do
    agent = start_sidecar!()
    sidecar = Process.whereis(Acp.Sidecar)
    ref = Process.monitor(sidecar)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:opencode_exit, :killed}}
  end

  test "an uplink crash starts another uplink" do
    _agent = start_sidecar!()
    first = Process.whereis(Acp.Uplink)
    Process.exit(first, :kill)
    Process.sleep(50)
    second = Process.whereis(Acp.Uplink)
    assert is_pid(second)
    assert second != first
    assert Process.alive?(Process.whereis(Acp.Sidecar))
  end

  test "stopping the sidecar closes the agent" do
    agent = start_sidecar!()
    ref = Process.monitor(agent)
    GenServer.stop(Acp.Sidecar)
    assert_receive {:DOWN, ^ref, :process, ^agent, _}
  end

  test "an unknown message is ignored" do
    _agent = start_sidecar!()
    send(Acp.Sidecar, :nope)
    Process.sleep(20)
    assert Process.alive?(Process.whereis(Acp.Sidecar))
  end

  defp start_sidecar! do
    start_supervised!(%{
      id: Acp.Sidecar,
      start: {Acp.Sidecar, :start_link, [[]]},
      restart: :temporary
    })

    assert_receive {:harness_opened, agent, cwd}
    assert cwd == "/tmp/acp-test-workdir"
    agent
  end

  defp wait_for(fun) do
    Enum.reduce_while(1..20, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(10) && {:cont, false}
    end)
  end

  defp uplink_outbox do
    :sys.get_state(Acp.Uplink).outbox
  end

  defp stop(name) do
    if pid = Process.whereis(name), do: Process.exit(pid, :kill)
  end
end
