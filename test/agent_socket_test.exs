defmodule Acp.AgentSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Acp.Registry)
    start_supervised!(Acp.Plane)
    :ok
  end

  test "an agent socket rejects a bad hello, then forwards ACP" do
    {:ok, state} = Acp.AgentSocket.init([])
    assert {:ok, ^state} = Acp.AgentSocket.handle_in({<<1>>, [opcode: :binary]}, state)

    assert {:stop, :expected_uplink, ^state} =
             Acp.AgentSocket.handle_in({"nope", [opcode: :text]}, state)

    bad = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "acp.uplink", "params" => %{"name" => "Bad Name"}})

    assert {:stop, "runtime name must be a short slug", ^state} =
             Acp.AgentSocket.handle_in({bad, [opcode: :text]}, state)

    hello = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "acp.uplink", "params" => %{"name" => "lab", "label" => "Bench"}})
    assert {:ok, named} = Acp.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    assert named.name == "lab"
    assert Acp.Registry.pid("lab") == self()

    frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{}})
    assert {:ok, ^named} = Acp.AgentSocket.handle_in({frame, [opcode: :text]}, named)
    assert {:ok, ^named} = Acp.AgentSocket.handle_in({<<9>>, [opcode: :binary]}, named)
    assert {:push, [{:text, "{}"}], ^named} = Acp.AgentSocket.handle_info({:send, "{}"}, named)
    assert {:ok, ^named} = Acp.AgentSocket.handle_info(:other, named)
    assert {:stop, :normal, ^named} = Acp.AgentSocket.handle_info(:replaced, named)
    assert :ok = Acp.AgentSocket.terminate(:normal, named)
  end
end
