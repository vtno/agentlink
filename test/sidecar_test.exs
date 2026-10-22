defmodule Pont.SidecarTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:pont, :harness_listener, self())

    on_exit(fn ->
      Application.delete_env(:pont, :harness_listener)
      stop(Pont.Sidecar)
      stop(Pont.Uplink)
    end)

    :ok
  end

  test "send_message is down when the sidecar is not running" do
    assert Pont.Sidecar.send_message(%{"method" => "ping"}) == :down
  end

  test "stdout lines reach the uplink, and a partial line waits" do
    agent = start_sidecar!()
    Pont.FakeHarness.emit(agent, ~s({"method":"hi"}))
    refute_receive {:harness_write, _}, 30
    Pont.FakeHarness.emit(agent, "\n")
    assert wait_for(fn -> %{"method" => "hi"} in uplink_outbox() end)

    Pont.FakeHarness.emit(agent, "not-json\n")
    Process.sleep(30)
    refute Enum.any?(uplink_outbox(), &(&1 == "not-json"))
  end

  test "a message from the plane is written to the agent" do
    _agent = start_sidecar!()
    send(Pont.Sidecar, {:from_plane, %{"method" => "ping"}})
    assert_receive {:harness_write, line}
    assert String.ends_with?(line, "\n")
    assert %{"method" => "ping"} = Jason.decode!(String.trim(line))
  end

  test "a closed agent stops the sidecar" do
    agent = start_sidecar!()
    sidecar = Process.whereis(Pont.Sidecar)
    ref = Process.monitor(sidecar)
    Pont.FakeHarness.refuse(agent)
    Pont.Sidecar.send_message(%{"method" => "x"})
    assert_receive {:DOWN, ^ref, :process, ^sidecar, :port_closed}
  end

  test "an exit status stops the sidecar" do
    agent = start_sidecar!()
    sidecar = Process.whereis(Pont.Sidecar)
    ref = Process.monitor(sidecar)
    Pont.FakeHarness.exit_status(agent, 3)
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:opencode_exit, 3}}
  end

  test "the agent process dying stops the sidecar" do
    agent = start_sidecar!()
    sidecar = Process.whereis(Pont.Sidecar)
    ref = Process.monitor(sidecar)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sidecar, {:opencode_exit, :killed}}
  end

  test "an uplink crash starts another uplink" do
    _agent = start_sidecar!()
    first = Process.whereis(Pont.Uplink)
    Process.exit(first, :kill)
    Process.sleep(50)
    second = Process.whereis(Pont.Uplink)
    assert is_pid(second)
    assert second != first
    assert Process.alive?(Process.whereis(Pont.Sidecar))
  end

  test "stopping the sidecar closes the agent" do
    agent = start_sidecar!()
    ref = Process.monitor(agent)
    GenServer.stop(Pont.Sidecar)
    assert_receive {:DOWN, ^ref, :process, ^agent, _}
  end

  test "an unknown message is ignored" do
    _agent = start_sidecar!()
    send(Pont.Sidecar, :nope)
    Process.sleep(20)
    assert Process.alive?(Process.whereis(Pont.Sidecar))
  end

  defp start_sidecar! do
    start_supervised!(%{
      id: Pont.Sidecar,
      start: {Pont.Sidecar, :start_link, [[]]},
      restart: :temporary
    })

    assert_receive {:harness_opened, agent, cwd}
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
