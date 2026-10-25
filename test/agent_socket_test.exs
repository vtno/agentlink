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

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:stop, :normal, {4001, ~s(another uplink registered as "lab")}, ^named} =
                 Pont.AgentSocket.handle_info(:replaced, named)
      end)

    assert log =~ "uplink replaced name=lab another uplink registered with the same name"
    assert :ok = Pont.AgentSocket.terminate(:normal, named)
  end
end
