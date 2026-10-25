defmodule Pont.AgentSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Pont.Registry)
    start_supervised!(Pont.Plane)
    :ok
  end

  test "an agent socket rejects a bad hello, then forwards ACP" do
    {:ok, state} = Pont.AgentSocket.init(%Pont.Access.Subject{id: "admin", role: :admin})
    assert {:ok, ^state} = Pont.AgentSocket.handle_in({<<1>>, [opcode: :binary]}, state)

    assert {:stop, :expected_uplink, ^state} =
             Pont.AgentSocket.handle_in({"nope", [opcode: :text]}, state)

    bad =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "pont.uplink",
        "params" => %{"name" => "Bad Name"}
      })

    assert {:stop, "link name must be a short slug", ^state} =
             Pont.AgentSocket.handle_in({bad, [opcode: :text]}, state)

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "pont.uplink",
        "params" => %{"name" => "lab", "label" => "Bench"}
      })

    assert {:ok, named} = Pont.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    assert named.name == "lab"
    assert Pont.Registry.pid("lab") == self()

    frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{}})
    assert {:ok, ^named} = Pont.AgentSocket.handle_in({frame, [opcode: :text]}, named)
    assert {:ok, ^named} = Pont.AgentSocket.handle_in({<<9>>, [opcode: :binary]}, named)
    assert {:push, [{:text, "{}"}], ^named} = Pont.AgentSocket.handle_info({:send, "{}"}, named)
    assert {:ok, ^named} = Pont.AgentSocket.handle_info(:other, named)
    assert :ok = Pont.AgentSocket.terminate(:normal, named)
  end

  test "a second hello for a live name closes only the new socket" do
    subject = %Pont.Access.Subject{id: "admin", role: :admin}
    {:ok, state} = Pont.AgentSocket.init(subject)

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "pont.uplink",
        "params" => %{"name" => "lab", "label" => "Bench"}
      })

    assert {:ok, named} = Pont.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    holder = self()
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          {:ok, other} = Pont.AgentSocket.init(subject)
          send(parent, {:rejected, Pont.AgentSocket.handle_in({hello, [opcode: :text]}, other)})
        end)

        assert_receive {:rejected, result}
        send(parent, {:checked, result})
      end)

    reason = Pont.AgentSocket.name_taken_reason("lab")
    assert_receive {:checked, {:stop, :normal, {4001, ^reason}, _other}}
    assert log =~ "uplink rejected name=lab another uplink is already connected with this name"
    assert Pont.Registry.pid("lab") == holder
    assert named.name == "lab"
    assert {:ok, ^named} = Pont.AgentSocket.handle_info(:other, named)
    refute_received :superseded
  end

  test "the same relay's hello stops the previous socket" do
    subject = %Pont.Access.Subject{id: "admin", role: :admin}
    {:ok, state} = Pont.AgentSocket.init(subject)

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "pont.uplink",
        "params" => %{"name" => "lab", "label" => "Bench", "instance" => "relay-a"}
      })

    assert {:ok, named} = Pont.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    parent = self()
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          {:ok, other} = Pont.AgentSocket.init(subject)
          send(parent, {:accepted, Pont.AgentSocket.handle_in({hello, [opcode: :text]}, other)})
          Process.sleep(:infinity)
        end)

        assert_receive {:accepted, {:ok, _other}}
      end)

    assert log =~ "uplink reconnect name=lab the same relay dialed again"
    assert_receive :superseded
    assert Pont.Registry.pid("lab") != self()

    stop_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:stop, :normal, ^named} = Pont.AgentSocket.handle_info(:superseded, named)
      end)

    assert stop_log =~ "agent socket superseded name=lab the same relay dialed again"
  end

  test "an oversized instance id closes the new socket and leaves the holder up" do
    subject = %Pont.Access.Subject{id: "admin", role: :admin}
    {:ok, state} = Pont.AgentSocket.init(subject)
    reason = Pont.AgentSocket.instance_too_long_reason()
    assert byte_size(reason) <= 123

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "pont.uplink",
        "params" => %{"name" => "lab", "label" => "Bench", "instance" => "relay-a"}
      })

    assert {:ok, named} = Pont.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    holder = self()
    parent = self()
    too_long = String.duplicate("c", Pont.Registry.max_instance_bytes() + 1)

    rejected =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "pont.uplink",
        "params" => %{"name" => "lab", "label" => "Other", "instance" => too_long}
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          {:ok, other} = Pont.AgentSocket.init(subject)

          send(
            parent,
            {:rejected, Pont.AgentSocket.handle_in({rejected, [opcode: :text]}, other)}
          )
        end)

        assert_receive {:rejected, result}
        send(parent, {:checked, result})
      end)

    code = Pont.AgentSocket.instance_too_long_close_code()
    assert_receive {:checked, {:stop, :normal, {^code, ^reason}, _other}}
    assert log =~ "uplink rejected name=lab instance id is too long"
    assert Pont.Registry.pid("lab") == holder
    assert named.name == "lab"
    refute_received :superseded
  end
end
