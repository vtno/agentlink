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

  test "the same relay instance releases the live holder and keeps the new socket" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(first, "lab", "a", "relay-a")

    log =
      Pont.TestHelpers.capture_info(fn ->
        assert :ok = hello(second, "lab", "b", "relay-a")
      end)

    assert log =~ "uplink reconnect name=lab the same relay dialed again"
    refute log =~ "uplink rejected name=lab"
    assert Pont.Registry.pid("lab") == second
    assert [%{"label" => "b"}] = Pont.Registry.list()
    assert Process.info(first, :messages) == {:messages, [:superseded]}

    Process.exit(first, :kill)
    Process.sleep(50)
    assert Pont.Registry.pid("lab") == second
    assert Process.alive?(second)
  end

  test "a different relay instance leaves the holder up and unsignaled" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(first, "lab", "a", "relay-a")

    assert {:error, {:name_taken, "lab"}} = hello(second, "lab", "b", "relay-b")
    assert Pont.Registry.pid("lab") == first
    assert [%{"label" => "a"}] = Pont.Registry.list()
    assert Process.info(first, :messages) == {:messages, []}
    assert Process.alive?(first)
  end

  test "a missing instance does not match a present one, or another missing one" do
    holder = spawn(fn -> Process.sleep(:infinity) end)
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(holder, "lab", "a", "relay-a")
    assert {:error, {:name_taken, "lab"}} = hello(other, "lab", "b")
    assert Process.info(holder, :messages) == {:messages, []}

    plain = spawn(fn -> Process.sleep(:infinity) end)
    challenger = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(plain, "bench", "a")
    assert {:error, {:name_taken, "bench"}} = hello(challenger, "bench", "b", "relay-a")
    assert Process.info(plain, :messages) == {:messages, []}
    assert Pont.Registry.pid("lab") == holder
    assert Pont.Registry.pid("bench") == plain
  end

  test "a blank instance does not count as the same relay" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(first, "lab", "a", "  ")
    assert {:error, {:name_taken, "lab"}} = hello(second, "lab", "b", "  ")
    assert Process.info(first, :messages) == {:messages, []}
    assert Pont.Registry.pid("lab") == first
  end

  test "distinct instance ids that share a long prefix leave the holder up" do
    prefix = String.duplicate("a", 80)
    holder_id = prefix <> "FIRST"
    other_id = prefix <> "SECOND"
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(first, "lab", "a", holder_id)

    assert {:error, {:name_taken, "lab"}} = hello(second, "lab", "b", other_id)
    assert Pont.Registry.pid("lab") == first
    assert [%{"label" => "a"}] = Pont.Registry.list()
    assert Process.info(first, :messages) == {:messages, []}
    assert Process.alive?(first)

    [{_, %Pont.Registry.Uplink{instance: stored}}] = :ets.lookup(:pont_runtimes, "lab")
    assert stored == holder_id
  end

  test "an instance id at the size limit is kept whole" do
    max = Pont.Registry.max_instance_bytes()
    id = String.duplicate("a", max)
    other_id = String.duplicate("a", max - 1) <> "b"
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert byte_size(id) == max
    assert :ok = hello(first, "lab", "a", "  #{id}  ")

    [{_, %Pont.Registry.Uplink{instance: stored}}] = :ets.lookup(:pont_runtimes, "lab")
    assert stored == id

    assert {:error, {:name_taken, "lab"}} = hello(second, "lab", "b", other_id)
    assert Pont.Registry.pid("lab") == first
    assert Process.info(first, :messages) == {:messages, []}
  end

  test "an oversized instance id is rejected and the holder stays" do
    max = Pont.Registry.max_instance_bytes()
    too_long = String.duplicate("b", max + 1)
    holder = spawn(fn -> Process.sleep(:infinity) end)
    other = spawn(fn -> Process.sleep(:infinity) end)
    fresh = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(holder, "lab", "a", "relay-a")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :instance_too_long} = hello(other, "lab", "b", too_long)
        assert {:error, :instance_too_long} = hello(fresh, "bench", "c", "  #{too_long}")
      end)

    assert log =~ "uplink rejected name=lab instance id is too long; max is #{max} bytes"
    assert log =~ "uplink rejected name=bench instance id is too long; max is #{max} bytes"
    assert Pont.Registry.pid("lab") == holder
    assert [%{"name" => "lab", "label" => "a"}] = Pont.Registry.list()
    assert Pont.Registry.pid("bench") == nil
    assert Process.info(holder, :messages) == {:messages, []}
    assert Process.alive?(holder)
    assert Process.alive?(other)
  end

  test "the same long instance id still releases the previous socket" do
    id = String.duplicate("a", 90)
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = hello(first, "lab", "a", id)
    [{_, %Pont.Registry.Uplink{instance: stored}}] = :ets.lookup(:pont_runtimes, "lab")
    assert stored == id
    assert :ok = hello(second, "lab", "b", id)
    assert Pont.Registry.pid("lab") == second
    assert Process.info(first, :messages) == {:messages, [:superseded]}
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

  defp hello(pid, name, label, instance \\ nil) do
    Pont.Registry.register(
      pid,
      %Pont.Registry.Uplink{name: name, label: label, instance: instance},
      %Pont.Access.Subject{id: "admin", role: :admin}
    )
  end
end
