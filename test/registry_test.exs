defmodule Pont.RegistryTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Pont.Registry)
    :ok
  end

  test "register, list, and pid" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(pid, "lab", "Bench")
    assert Pont.Registry.pid("lab") == pid

    assert [%{"name" => "lab", "label" => "Bench", "program" => "opencode", "connected_at" => at}] =
             Pont.Registry.list()

    assert is_integer(at)
  end

  test "rejects a bad name and a missing name" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:error, "link name must be a short slug"} = hello(pid, "Has Space", "x")
    assert {:error, "link name must be a short slug"} = hello(pid, 1, "x")
    assert Pont.Registry.list() == []
    assert Pont.Registry.pid("nope") == nil
  end

  test "an empty label uses the name, and a long label is cut" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = hello(pid, "lab", "  ")
    assert [%{"name" => "lab", "label" => "lab"}] = Pont.Registry.list()

    other = spawn(fn -> Process.sleep(:infinity) end)
    :ok = hello(other, "bench", String.duplicate("n", 100))
    assert %{"label" => label} = Enum.find(Pont.Registry.list(), &(&1["name"] == "bench"))
    assert String.length(label) == 80
  end

  test "a second socket with a live name is rejected and the holder stays" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(first, "lab", "a")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:name_taken, "lab"}} = hello(second, "lab", "b")
      end)

    assert log =~ "uplink rejected name=lab another uplink is already connected with this name"
    assert Pont.Registry.pid("lab") == first
    assert [%{"label" => "a"}] = Pont.Registry.list()
    assert Process.info(first, :messages) == {:messages, []}
    assert Process.alive?(first)
    assert Process.alive?(second)
  end

  test "the holder registering again leaves the row untouched" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(pid, "lab", "a")
    assert :ok = hello(pid, "lab", "b")
    assert Pont.Registry.pid("lab") == pid
    assert [%{"label" => "a"}] = Pont.Registry.list()
  end

  test "two hellos at once still leave one live holder" do
    parent = self()
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)

    for {pid, label} <- [{first, "a"}, {second, "b"}] do
      spawn(fn -> send(parent, {pid, hello(pid, "lab", label)}) end)
    end

    assert_receive {^first, result_a}
    assert_receive {^second, result_b}
    assert Enum.sort([result_a, result_b]) == [:ok, {:error, {:name_taken, "lab"}}]
    winner = if result_a == :ok, do: first, else: second
    loser = if winner == first, do: second, else: first
    assert Pont.Registry.pid("lab") == winner
    assert Process.alive?(winner)
    assert Process.alive?(loser)
    assert Process.info(winner, :messages) == {:messages, []}
    assert Process.info(loser, :messages) == {:messages, []}
  end

  test "a dead socket is removed, and an unknown down is ignored" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = hello(pid, "lab", "a")
    Process.exit(pid, :kill)
    Process.sleep(30)
    assert Pont.Registry.list() == []

    send(Pont.Registry, {:DOWN, make_ref(), :process, pid, :killed})
    other = spawn(fn -> Process.sleep(:infinity) end)
    :ok = hello(other, "lab", "b")
    send(Pont.Registry, {:DOWN, make_ref(), :process, self(), :killed})
    assert [%{"name" => "lab"}] = Pont.Registry.list()
  end

  test "a stale row whose process is already dead does not block the next hello" do
    holder = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(holder, "lab", "a")
    [{_, %Pont.Registry.Uplink{} = uplink}] = :ets.lookup(:pont_runtimes, "lab")

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    :ets.insert(:pont_runtimes, {"lab", %{uplink | pid: dead}})

    next = spawn(fn -> Process.sleep(:infinity) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = hello(next, "lab", "b")
      end)

    assert log =~ "uplink stale name=lab the previous holder was already dead"
    assert Pont.Registry.pid("lab") == next

    Process.exit(holder, :kill)
    Process.sleep(50)
    assert Pont.Registry.pid("lab") == next
    assert Process.alive?(next)
  end

  defp hello(pid, name, label) do
    Pont.Registry.register(
      pid,
      %Pont.Registry.Uplink{name: name, label: label},
      %Pont.Access.Subject{id: "admin", role: :admin}
    )
  end
end
