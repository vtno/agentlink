defmodule AgentLink.ClientSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane.Sessions)
    start_supervised!(AgentLink.Plane)
    :ok
  end

  test "a client socket registers, forwards text, and pushes a reply" do
    {:ok, state} = AgentLink.ClientSocket.init(%AgentLink.Access.Subject{})
    assert is_binary(state.id)

    {:ok, state} =
      AgentLink.ClientSocket.handle_in(
        {~s({"jsonrpc":"2.0","method":"runtime/list"}), [opcode: :text]},
        state
      )

    {:ok, state} = AgentLink.ClientSocket.handle_in({<<1, 2>>, [opcode: :binary]}, state)

    assert {:push, [{:text, "{}"}], ^state} =
             AgentLink.ClientSocket.handle_info({:send, "{}"}, state)

    assert {:ok, ^state} = AgentLink.ClientSocket.handle_info(:other, state)
    assert :ok = AgentLink.ClientSocket.terminate(:normal, state)
  end
end
