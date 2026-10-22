defmodule Pont.RegistryTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Pont.Registry)
    :ok
  end

  test "register, list, and pid" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Pont.Registry.register(pid, "lab", "Bench")
    assert Pont.Registry.pid("lab") == pid
    assert [%{"name" => "lab", "label" => "Bench", "connected_at" => at}] = Pont.Registry.list()
    assert is_integer(at)
  end

  test "rejects a bad name and a missing name" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:error, "runtime name must be a short slug"} = Pont.Registry.register(pid, "Has Space", "x")
    assert {:error, "runtime name must be a short slug"} = Pont.Registry.register(pid, 1, "x")
    assert Pont.Registry.list() == []
    assert Pont.Registry.pid("nope") == nil
  end

  test "an empty label uses the name, and a long label is cut" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Pont.Registry.register(pid, "lab", "  ")
    assert [%{"label" => "lab"}] = Pont.Registry.list()

    :ok = Pont.Registry.register(pid, "lab", String.duplicate("n", 100))
    assert [%{"label" => label}] = Pont.Registry.list()
    assert String.length(label) == 80
  end

  test "a new socket with the same name replaces the old one" do
    parent = self()
    first = spawn(fn -> receive do: (:replaced -> send(parent, :replaced)) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Pont.Registry.register(first, "lab", "a")
    :ok = Pont.Registry.register(second, "lab", "b")
    assert Pont.Registry.pid("lab") == second
    assert_receive :replaced
  end

  test "a dead socket is removed, and an unknown down is ignored" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Pont.Registry.register(pid, "lab", "a")
    Process.exit(pid, :kill)
    Process.sleep(30)
    assert Pont.Registry.list() == []

    send(Pont.Registry, {:DOWN, make_ref(), :process, pid, :killed})
    other = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Pont.Registry.register(other, "lab", "b")
    send(Pont.Registry, {:DOWN, make_ref(), :process, self(), :killed})
    assert [%{"name" => "lab"}] = Pont.Registry.list()
  end

  test "when the name was already replaced, down does not delete the new row" do
    first = spawn(fn -> receive do: (:replaced -> Process.sleep(:infinity)) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Pont.Registry.register(first, "lab", "a")
    :ok = Pont.Registry.register(second, "lab", "b")
    Process.exit(first, :kill)
    Process.sleep(50)
    assert Pont.Registry.pid("lab") == second
  end
end
