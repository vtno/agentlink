defmodule AgentLink.KeepaliveTest do
  use ExUnit.Case, async: false

  alias AgentLink.FakeScheduler
  alias AgentLink.Keepalive

  test "a tick sends one ping and the next ping leaves the deadline where it is" do
    start_supervised!(FakeScheduler)
    keepalive = Keepalive.arm(keepalive(), self())

    assert FakeScheduler.scheduled(keepalive.ping_timer) ==
             {self(), {:keepalive_ping, keepalive.ping_token}, 30_000}

    assert {:push, [{:ping, ""}], armed} =
             Keepalive.handle_info({:keepalive_ping, keepalive.ping_token}, keepalive, self())

    assert FakeScheduler.scheduled(armed.pong_timer) ==
             {self(), {:keepalive_expired, armed.pong_token}, 10_000}

    assert {:push, [{:ping, ""}], again} =
             Keepalive.handle_info({:keepalive_ping, armed.ping_token}, armed, self())

    assert again.pong_timer == armed.pong_timer
    assert again.pong_token == armed.pong_token

    assert :ignore = Keepalive.handle_info({:keepalive_ping, keepalive.ping_token}, again, self())
    assert :ignore = Keepalive.handle_info(:other, again, self())
  end

  test "a pong clears the deadline and a stale expiry is ignored" do
    start_supervised!(FakeScheduler)
    keepalive = Keepalive.arm(keepalive(), self())

    {:push, _, armed} =
      Keepalive.handle_info({:keepalive_ping, keepalive.ping_token}, keepalive, self())

    assert {:ok, cleared} = Keepalive.handle_control({"", [opcode: :pong]}, armed)
    assert cleared.pong_timer == nil
    assert cleared.pong_token == nil
    assert FakeScheduler.scheduled(armed.pong_timer) == nil
    assert {:ok, ^cleared} = Keepalive.handle_control({"z", [opcode: :ping]}, cleared)

    assert :ignore =
             Keepalive.handle_info({:keepalive_expired, armed.pong_token}, cleared, self())
  end

  test "a missed pong stops the socket and cancels both timers" do
    start_supervised!(FakeScheduler)
    keepalive = Keepalive.arm(keepalive(), self())

    {:push, _, armed} =
      Keepalive.handle_info({:keepalive_ping, keepalive.ping_token}, keepalive, self())

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:stop, {:shutdown, :keepalive_pong_timeout}, {1001, "keepalive pong timeout"},
                stopped} =
                 Keepalive.handle_info(
                   {:keepalive_expired, armed.pong_token},
                   armed,
                   self()
                 )

        assert stopped.ping_timer == nil
        assert stopped.pong_timer == nil
        assert stopped.ping_token == nil
        assert stopped.pong_token == nil

        assert :ignore =
                 Keepalive.handle_info(
                   {:keepalive_expired, armed.pong_token},
                   stopped,
                   self()
                 )
      end)

    assert log =~ "plane keepalive expired"
    assert FakeScheduler.scheduled(armed.ping_timer) == nil
    assert FakeScheduler.scheduled(armed.pong_timer) == nil
  end

  test "durations follow an option, then the environment, then application config" do
    previous = %{
      interval: Application.get_env(:agent_link, :websocket_ping_interval),
      timeout: Application.get_env(:agent_link, :websocket_pong_timeout),
      interval_env: System.get_env("AGENTLINK_WEBSOCKET_PING_INTERVAL"),
      timeout_env: System.get_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT")
    }

    on_exit(fn ->
      restore_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", previous.interval_env)
      restore_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT", previous.timeout_env)
      AgentLink.TestHelpers.restore(:websocket_ping_interval, previous.interval)
      AgentLink.TestHelpers.restore(:websocket_pong_timeout, previous.timeout)
    end)

    System.delete_env("AGENTLINK_WEBSOCKET_PING_INTERVAL")
    System.delete_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT")
    Application.delete_env(:agent_link, :websocket_ping_interval)
    Application.delete_env(:agent_link, :websocket_pong_timeout)

    assert Keepalive.milliseconds(
             [],
             :ping_interval,
             :websocket_ping_interval,
             "AGENTLINK_WEBSOCKET_PING_INTERVAL",
             30_000
           ) ==
             30_000

    Application.put_env(:agent_link, :websocket_ping_interval, 45_000)
    Application.put_env(:agent_link, :websocket_pong_timeout, 9_000)

    assert Keepalive.new([]).interval == 45_000
    assert Keepalive.new([]).timeout == 9_000

    System.put_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", "12000")
    System.put_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT", "4000")
    from_env = Keepalive.new([])
    assert from_env.interval == 12_000
    assert from_env.timeout == 4_000

    from_opts = Keepalive.new(ping_interval: 15_000, pong_timeout: 5_000)
    assert from_opts.interval == 15_000
    assert from_opts.timeout == 5_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        System.put_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", "nope")

        assert Keepalive.milliseconds(
                 [],
                 :ping_interval,
                 :websocket_ping_interval,
                 "AGENTLINK_WEBSOCKET_PING_INTERVAL",
                 30_000
               ) == 45_000

        assert Keepalive.new([]).interval == 45_000
      end)

    assert log =~ "transport keepalive AGENTLINK_WEBSOCKET_PING_INTERVAL ignored \"nope\""
    assert log =~ "plane keepalive AGENTLINK_WEBSOCKET_PING_INTERVAL ignored \"nope\""
  end

  defp keepalive do
    Keepalive.new(scheduler: FakeScheduler, ping_interval: 30_000, pong_timeout: 10_000)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
