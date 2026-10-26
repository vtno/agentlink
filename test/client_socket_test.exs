defmodule Pont.ClientSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Pont.Registry)
    start_supervised!(Pont.Plane)
    :ok
  end

  test "a client socket registers, forwards text, and pushes a reply" do
    {:ok, state} = Pont.ClientSocket.init(%Pont.Access.Subject{})
    assert is_binary(state.id)

    {:ok, state} =
      Pont.ClientSocket.handle_in(
        {~s({"jsonrpc":"2.0","method":"runtime/list"}), [opcode: :text]},
        state
      )

    {:ok, state} = Pont.ClientSocket.handle_in({<<1, 2>>, [opcode: :binary]}, state)
    assert {:push, [{:text, "{}"}], ^state} = Pont.ClientSocket.handle_info({:send, "{}"}, state)
    assert {:ok, ^state} = Pont.ClientSocket.handle_info(:other, state)
    assert :ok = Pont.ClientSocket.terminate(:normal, state)
  end
end
