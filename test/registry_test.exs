defmodule AgentLink.RegistryTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(AgentLink.Registry)
    :ok
  end

  test "register, list, and pid" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(pid, "lab", "Bench")
    assert AgentLink.Registry.pid("lab") == pid

    assert [%{"name" => "lab", "label" => "Bench", "program" => "opencode", "connected_at" => at}] =
             AgentLink.Registry.list()

    assert is_integer(at)
  end

  test "rejects a bad name and a missing name" do
    pid = spawn(fn -> Process.sleep(:infinity) end)

    for name <- ["Has Space", "", "  ", nil, 1, String.duplicate("a", 41)] do
      assert {:error, :bad_name} = hello(pid, name, "x")
    end

    assert AgentLink.Registry.list() == []
    assert AgentLink.Registry.pid("nope") == nil
  end

  test "returns the normalized name, including when the holder registers again" do
    assert {:ok, "lab"} = hello(self(), "  lab\t", "Bench")
    assert {:ok, "lab"} = hello(self(), " lab ", "Other")
    assert AgentLink.Registry.pid("lab") == self()
    assert AgentLink.Registry.pid("  lab\t") == nil
    assert [%{"name" => "lab", "label" => "Bench"}] = AgentLink.Registry.list()
  end

  test "a policy rejection neither registers a name nor changes its holder" do
    assert {:ok, "lab"} = hello(self(), "lab", "Bench")
    subject = %AgentLink.Access.Subject{id: "user", role: :user}

    for name <- [" lab ", "bench"] do
      assert {:error, :not_allowed} =
               AgentLink.Registry.register(
                 self(),
                 %AgentLink.Registry.Uplink{name: name},
                 subject
               )
    end

    assert AgentLink.Registry.pid("lab") == self()
    assert [%{"name" => "lab", "label" => "Bench"}] = AgentLink.Registry.list()
    refute_received :superseded
  end

  test "a name at the character limit is kept, and a longer one is rejected" do
    max = AgentLink.Registry.max_name_chars()
    at_max = String.duplicate("a", max)
    too_long = String.duplicate("b", max + 1)
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, ^at_max} = hello(pid, at_max, "x")
    assert AgentLink.Registry.pid(at_max) == pid

    other = spawn(fn -> Process.sleep(:infinity) end)
    assert {:error, :bad_name} = hello(other, too_long, "x")
    assert AgentLink.Registry.pid(too_long) == nil
  end

  test "an empty label uses the name, and a long label is cut" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, "lab"} = hello(pid, "lab", "  ")
    assert [%{"name" => "lab", "label" => "lab"}] = AgentLink.Registry.list()

    other = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, "bench"} = hello(other, "bench", String.duplicate("n", 100))
    assert %{"label" => label} = Enum.find(AgentLink.Registry.list(), &(&1["name"] == "bench"))
    assert String.length(label) == 80
  end

  test "a second socket with a live name is rejected and the holder stays" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(first, "lab", "a")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :name_taken} = hello(second, "lab", "b")
      end)

    assert log =~ "uplink rejected name=lab another uplink is already connected with this name"
    assert AgentLink.Registry.pid("lab") == first
    assert [%{"label" => "a"}] = AgentLink.Registry.list()
    assert Process.info(first, :messages) == {:messages, []}
    assert Process.alive?(first)
    assert Process.alive?(second)
  end

  test "the same relay instance releases the live holder and keeps the new socket" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(first, "lab", "a", "relay-a")

    log =
      AgentLink.TestHelpers.capture_info(fn ->
        assert {:ok, "lab"} = hello(second, "lab", "b", "relay-a")
      end)

    assert log =~ "uplink reconnect name=lab the same relay dialed again"
    refute log =~ "uplink rejected name=lab"
    assert AgentLink.Registry.pid("lab") == second
    assert [%{"label" => "b"}] = AgentLink.Registry.list()
    assert Process.info(first, :messages) == {:messages, [:superseded]}

    AgentLink.TestHelpers.kill_and_wait(first)
    assert AgentLink.Registry.pid("lab") == second
    assert Process.alive?(second)
  end

  test "a different relay instance leaves the holder up and unsignaled" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(first, "lab", "a", "relay-a")

    assert {:error, :name_taken} = hello(second, "lab", "b", "relay-b")
    assert AgentLink.Registry.pid("lab") == first
    assert [%{"label" => "a"}] = AgentLink.Registry.list()
    assert Process.info(first, :messages) == {:messages, []}
    assert Process.alive?(first)
  end

  test "a missing instance does not match a present one, or another missing one" do
    holder = spawn(fn -> Process.sleep(:infinity) end)
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(holder, "lab", "a", "relay-a")
    assert {:error, :name_taken} = hello(other, "lab", "b")
    assert Process.info(holder, :messages) == {:messages, []}

    plain = spawn(fn -> Process.sleep(:infinity) end)
    challenger = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "bench"} = hello(plain, "bench", "a")
    assert {:error, :name_taken} = hello(challenger, "bench", "b", "relay-a")
    assert Process.info(plain, :messages) == {:messages, []}
    assert AgentLink.Registry.pid("lab") == holder
    assert AgentLink.Registry.pid("bench") == plain
  end

  test "a blank instance does not count as the same relay" do
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(first, "lab", "a", "  ")
    assert {:error, :name_taken} = hello(second, "lab", "b", "  ")
    assert Process.info(first, :messages) == {:messages, []}
    assert AgentLink.Registry.pid("lab") == first
  end

  test "distinct instance ids that share a long prefix leave the holder up" do
    prefix = String.duplicate("a", 80)
    holder_id = prefix <> "FIRST"
    other_id = prefix <> "SECOND"
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(first, "lab", "a", holder_id)

    assert {:error, :name_taken} = hello(second, "lab", "b", other_id)
    assert AgentLink.Registry.pid("lab") == first
    assert [%{"label" => "a"}] = AgentLink.Registry.list()
    assert Process.info(first, :messages) == {:messages, []}
    assert Process.alive?(first)

    [{_, %AgentLink.Registry.Uplink{instance: stored}}] = :ets.lookup(:agent_link_runtimes, "lab")
    assert stored == holder_id
  end

  test "an instance id at the size limit is kept whole" do
    max = AgentLink.AgentSocketProtocol.max_instance_bytes()
    id = String.duplicate("a", max)
    other_id = String.duplicate("a", max - 1) <> "b"
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert byte_size(id) == max
    assert {:ok, "lab"} = hello(first, "lab", "a", "  #{id}  ")

    [{_, %AgentLink.Registry.Uplink{instance: stored}}] = :ets.lookup(:agent_link_runtimes, "lab")
    assert stored == id

    assert {:error, :name_taken} = hello(second, "lab", "b", other_id)
    assert AgentLink.Registry.pid("lab") == first
    assert Process.info(first, :messages) == {:messages, []}
  end

  test "an oversized instance id is rejected and the holder stays" do
    max = AgentLink.AgentSocketProtocol.max_instance_bytes()
    too_long = String.duplicate("b", max + 1)
    holder = spawn(fn -> Process.sleep(:infinity) end)
    other = spawn(fn -> Process.sleep(:infinity) end)
    fresh = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(holder, "lab", "a", "relay-a")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :instance_too_long} = hello(other, "lab", "b", too_long)
        assert {:error, :instance_too_long} = hello(fresh, "bench", "c", "  #{too_long}")
      end)

    assert log =~ "uplink rejected name=lab instance id is too long; max is #{max} bytes"
    assert log =~ "uplink rejected name=bench instance id is too long; max is #{max} bytes"
    assert AgentLink.Registry.pid("lab") == holder
    assert [%{"name" => "lab", "label" => "a"}] = AgentLink.Registry.list()
    assert AgentLink.Registry.pid("bench") == nil
    assert Process.info(holder, :messages) == {:messages, []}
    assert Process.alive?(holder)
    assert Process.alive?(other)
  end

  test "the same long instance id still releases the previous socket" do
    id = String.duplicate("a", 90)
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(first, "lab", "a", id)
    [{_, %AgentLink.Registry.Uplink{instance: stored}}] = :ets.lookup(:agent_link_runtimes, "lab")
    assert stored == id
    assert {:ok, "lab"} = hello(second, "lab", "b", id)
    assert AgentLink.Registry.pid("lab") == second
    assert Process.info(first, :messages) == {:messages, [:superseded]}
  end

  test "the holder registering again leaves the row untouched" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(pid, "lab", "a")
    assert {:ok, "lab"} = hello(pid, "lab", "b")
    assert AgentLink.Registry.pid("lab") == pid
    assert [%{"label" => "a"}] = AgentLink.Registry.list()
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
    assert Enum.sort([result_a, result_b]) == [{:error, :name_taken}, {:ok, "lab"}]
    winner = if result_a == {:ok, "lab"}, do: first, else: second
    loser = if winner == first, do: second, else: first
    assert AgentLink.Registry.pid("lab") == winner
    assert Process.alive?(winner)
    assert Process.alive?(loser)
    assert Process.info(winner, :messages) == {:messages, []}
    assert Process.info(loser, :messages) == {:messages, []}
  end

  test "a dead socket is removed, and an unknown down is ignored" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, "lab"} = hello(pid, "lab", "a")
    AgentLink.TestHelpers.kill_and_wait(pid)
    AgentLink.TestHelpers.await(fn -> AgentLink.Registry.list() == [] end)

    send(AgentLink.Registry, {:DOWN, make_ref(), :process, pid, :killed})
    other = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, "lab"} = hello(other, "lab", "b")
    send(AgentLink.Registry, {:DOWN, make_ref(), :process, self(), :killed})
    assert [%{"name" => "lab"}] = AgentLink.Registry.list()
  end

  test "a stale row whose process is already dead does not block the next hello" do
    holder = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, "lab"} = hello(holder, "lab", "a")
    [{_, %AgentLink.Registry.Uplink{} = uplink}] = :ets.lookup(:agent_link_runtimes, "lab")

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    AgentLink.TestHelpers.await_down(ref, dead)
    :ets.insert(:agent_link_runtimes, {"lab", %{uplink | pid: dead}})

    next = spawn(fn -> Process.sleep(:infinity) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, "lab"} = hello(next, "lab", "b")
      end)

    assert log =~ "uplink stale name=lab the previous holder was already dead"
    assert AgentLink.Registry.pid("lab") == next

    AgentLink.TestHelpers.kill_and_wait(holder)
    assert AgentLink.Registry.pid("lab") == next
    assert Process.alive?(next)
  end

  defp hello(pid, name, label, instance \\ nil) do
    AgentLink.Registry.register(
      pid,
      %AgentLink.Registry.Uplink{name: name, label: label, instance: instance},
      %AgentLink.Access.Subject{id: "admin", role: :admin}
    )
  end
end
