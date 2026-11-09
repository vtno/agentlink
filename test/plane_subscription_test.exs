defmodule AgentLink.Plane.SubscriptionTest do
  use ExUnit.Case, async: true

  alias AgentLink.FakeSubscribe
  alias AgentLink.Frame
  alias AgentLink.Plane.Subscription

  test "notify sends the encoded object to the client" do
    owner = parked()
    first = %{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"n" => 1}}
    second = %{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"n" => 2}}
    pid = start!(Subscription, client_pid: self(), owner: owner)

    assert :ok = Subscription.notify(pid, first)
    assert :ok = Subscription.notify(pid, second)

    assert_received {:send, encoded_first}
    assert_received {:send, encoded_second}
    assert encoded_first == Frame.encode(first)
    assert encoded_second == Frame.encode(second)
    assert Process.info(owner, :messages) == {:messages, []}
  end

  test "a dead client tells the owner and stops the subscription" do
    assert_client_down(Subscription)
  end

  test "stop ends the subscription and does not tell the owner" do
    assert_stop(Subscription)
  end

  test "FakeSubscribe records notify and does not send to the client" do
    first = %{"method" => "session/update", "params" => %{"n" => 1}}
    second = %{"method" => "session/update", "params" => %{"n" => 2}}
    pid = start!(FakeSubscribe, client_pid: self())

    assert :ok = FakeSubscribe.notify(pid, first)
    assert :ok = FakeSubscribe.notify(pid, second)

    assert FakeSubscribe.notified(pid) == [first, second]
    refute_received {:send, _}
  end

  test "a dead client tells the owner and stops FakeSubscribe" do
    assert_client_down(FakeSubscribe)
  end

  test "FakeSubscribe stop ends the process and does not tell the owner" do
    assert_stop(FakeSubscribe)
  end

  test "client_pid, owner, client_id, and session_id are checked" do
    for module <- [Subscription, FakeSubscribe] do
      assert_raise ArgumentError, ~r/:client_pid/, fn ->
        module.start_link(opts(client_pid: "nope"))
      end

      assert_raise ArgumentError, ~r/:owner/, fn ->
        module.start_link(opts(owner: "nope"))
      end

      assert_raise ArgumentError, ~r/:client_id/, fn ->
        module.start_link(opts(client_id: :nope))
      end

      assert_raise ArgumentError, ~r/:session_id/, fn ->
        module.start_link(opts(session_id: :nope))
      end

      assert_raise KeyError, fn ->
        module.start_link(Keyword.delete(opts(), :owner))
      end
    end
  end

  defp assert_client_down(module) do
    client = parked()
    pid = start!(module, client_pid: client, client_id: "client-1", session_id: "session-1")
    ref = Process.monitor(pid)

    Process.exit(client, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert_received {:subscription_down, "client-1", "session-1"}
    refute Process.alive?(pid)
  end

  defp assert_stop(module) do
    client = parked()
    pid = start!(module, client_pid: client)
    ref = Process.monitor(pid)

    assert :ok = module.stop(pid)
    refute Process.alive?(pid)
    assert_received {:DOWN, ^ref, :process, ^pid, :normal}
    refute_received {:subscription_down, _, _}
    assert Process.info(client, :messages) == {:messages, []}
    assert :ok = module.stop(pid)
  end

  defp start!(module, overrides) do
    {:ok, pid} = module.start_link(opts(overrides))
    pid
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [client_pid: self(), client_id: "client", session_id: "session", owner: self()],
      overrides
    )
  end

  defp parked do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
