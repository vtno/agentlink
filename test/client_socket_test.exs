defmodule Acp.ClientSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Acp.Registry)
    start_supervised!(Acp.Plane)
    :ok
  end

  test "a client socket registers, forwards text, and pushes a reply" do
    {:ok, state} = Acp.ClientSocket.init([])
    assert is_binary(state.id)

    {:ok, state} = Acp.ClientSocket.handle_in({~s({"jsonrpc":"2.0","method":"runtime/list"}), [opcode: :text]}, state)
    {:ok, state} = Acp.ClientSocket.handle_in({<<1, 2>>, [opcode: :binary]}, state)
    assert {:push, [{:text, "{}"}], ^state} = Acp.ClientSocket.handle_info({:send, "{}"}, state)
    assert {:ok, ^state} = Acp.ClientSocket.handle_info(:other, state)
    assert :ok = Acp.ClientSocket.terminate(:normal, state)
  end
end
