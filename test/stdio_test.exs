defmodule AgentLink.StdioTest do
  use ExUnit.Case, async: true

  alias AgentLink.Stdio.Console

  test "open from another process returns an error and does not open a port" do
    assert {:error, message} = Console.open(spawn(fn -> :ok end))
    assert message == "AgentLink.Stdio.Console.open/1 must be called from the owner"
  end

  test "write and close report a term that is not an open port as closed" do
    assert Console.write(self(), "hi") == :closed
    assert Console.close(self()) == :ok

    port = Port.open({:spawn_executable, "/bin/true"}, [:binary, :exit_status])
    ref = Port.monitor(port)

    receive do
      {:DOWN, ^ref, :port, ^port, _reason} -> :ok
    end

    assert Console.write(port, "x") == :closed
    assert Console.close(port) == :ok
  end
end
