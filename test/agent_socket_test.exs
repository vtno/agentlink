defmodule AgentLink.AgentSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane.Sessions)
    start_supervised!(AgentLink.Plane)
    :ok
  end

  test "an agent socket rejects a bad hello, then forwards ACP" do
    {:ok, state} =
      AgentLink.AgentSocket.init(%AgentLink.Access.Subject{id: "admin", role: :admin})

    assert {:ok, ^state} = AgentLink.AgentSocket.handle_in({<<1>>, [opcode: :binary]}, state)

    assert {:stop, :expected_uplink, ^state} =
             AgentLink.AgentSocket.handle_in({"nope", [opcode: :text]}, state)

    bad =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "Bad Name"}
      })

    assert {:stop, :normal, {4003, "link name must be a short slug"}, ^state} =
             AgentLink.AgentSocket.handle_in({bad, [opcode: :text]}, state)

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "lab", "label" => "Bench"}
      })

    assert {:ok, named} = AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    assert named.name == "lab"
    assert AgentLink.Registry.pid("lab") == self()

    frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{}})
    assert {:ok, ^named} = AgentLink.AgentSocket.handle_in({frame, [opcode: :text]}, named)
    assert {:ok, ^named} = AgentLink.AgentSocket.handle_in({<<9>>, [opcode: :binary]}, named)

    assert {:push, [{:text, "{}"}], ^named} =
             AgentLink.AgentSocket.handle_info({:send, "{}"}, named)

    assert {:ok, ^named} = AgentLink.AgentSocket.handle_info(:other, named)
    assert :ok = AgentLink.AgentSocket.terminate(:normal, named)
  end

  test "a second hello for a live name closes only the new socket" do
    subject = %AgentLink.Access.Subject{id: "admin", role: :admin}
    {:ok, state} = AgentLink.AgentSocket.init(subject)

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "lab", "label" => "Bench"}
      })

    assert {:ok, named} = AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    holder = self()
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          {:ok, other} = AgentLink.AgentSocket.init(subject)

          send(
            parent,
            {:rejected, AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, other)}
          )
        end)

        assert_receive {:rejected, result}
        send(parent, {:checked, result})
      end)

    reason = AgentLink.AgentSocketProtocol.reason(:name_taken, "lab")
    assert_receive {:checked, {:stop, :normal, {4001, ^reason}, _other}}
    assert log =~ "uplink rejected name=lab another uplink is already connected with this name"
    assert AgentLink.Registry.pid("lab") == holder
    assert named.name == "lab"
    assert {:ok, ^named} = AgentLink.AgentSocket.handle_info(:other, named)
    refute_received :superseded
  end

  test "all invalid hello names close with the bad-name code" do
    {:ok, state} = AgentLink.AgentSocket.init(%AgentLink.Access.Subject{role: :admin})

    for name <- [nil, 1, "", "  ", "Bad Name", String.duplicate("a", 41)] do
      hello = Jason.encode!(%{"method" => "agentlink.uplink", "params" => %{"name" => name}})

      assert {:stop, :normal, {4003, "link name must be a short slug"}, ^state} =
               AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    end

    assert AgentLink.Registry.list() == []
  end

  test "a policy rejection closes with the not-allowed code" do
    {:ok, state} = AgentLink.AgentSocket.init(%AgentLink.Access.Subject{role: :user})
    hello = Jason.encode!(%{"method" => "agentlink.uplink", "params" => %{"name" => "lab"}})

    assert {:stop, :normal, {4004, "uplink is not allowed"}, ^state} =
             AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)

    assert AgentLink.Registry.list() == []
  end

  test "a padded hello routes later agent replies under the normalized name" do
    subject = %AgentLink.Access.Subject{role: :admin}
    {:ok, state} = AgentLink.AgentSocket.init(subject)
    hello = Jason.encode!(%{"method" => "agentlink.uplink", "params" => %{"name" => "  lab\t"}})
    assert {:ok, named} = AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    assert named.name == "lab"
    assert AgentLink.Registry.pid("lab") == self()

    client = AgentLink.Plane.register(self(), subject)
    AgentLink.Plane.client_frame(client, ~s({"jsonrpc":"2.0","id":7,"method":"session/new"}))
    assert_receive {:send, request}
    assert %{"method" => "session/new", "id" => agent_id} = Jason.decode!(request)

    reply =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"sessionId" => "s"}})

    assert {:ok, ^named} = AgentLink.AgentSocket.handle_in({reply, [opcode: :text]}, named)
    assert_receive {:send, response}
    assert %{"id" => 7, "result" => %{"sessionId" => "s"}} = Jason.decode!(response)
  end

  test "the same relay's hello stops the previous socket" do
    subject = %AgentLink.Access.Subject{id: "admin", role: :admin}
    {:ok, state} = AgentLink.AgentSocket.init(subject)

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "lab", "label" => "Bench", "instance" => "relay-a"}
      })

    assert {:ok, named} = AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    parent = self()
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          {:ok, other} = AgentLink.AgentSocket.init(subject)

          send(
            parent,
            {:accepted, AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, other)}
          )

          Process.sleep(:infinity)
        end)

        assert_receive {:accepted, {:ok, _other}}
      end)

    assert log =~ "uplink reconnect name=lab the same relay dialed again"
    assert_receive :superseded
    assert AgentLink.Registry.pid("lab") != self()

    stop_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:stop, :normal, ^named} = AgentLink.AgentSocket.handle_info(:superseded, named)
      end)

    assert stop_log =~ "agent socket superseded name=lab the same relay dialed again"
  end

  test "an oversized instance id closes the new socket and leaves the holder up" do
    subject = %AgentLink.Access.Subject{id: "admin", role: :admin}
    {:ok, state} = AgentLink.AgentSocket.init(subject)
    reason = AgentLink.AgentSocketProtocol.reason(:instance_too_long)
    assert byte_size(reason) <= 123

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "lab", "label" => "Bench", "instance" => "relay-a"}
      })

    assert {:ok, named} = AgentLink.AgentSocket.handle_in({hello, [opcode: :text]}, state)
    holder = self()
    parent = self()
    too_long = String.duplicate("c", AgentLink.AgentSocketProtocol.max_instance_bytes() + 1)

    rejected =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "lab", "label" => "Other", "instance" => too_long}
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          {:ok, other} = AgentLink.AgentSocket.init(subject)

          send(
            parent,
            {:rejected, AgentLink.AgentSocket.handle_in({rejected, [opcode: :text]}, other)}
          )
        end)

        assert_receive {:rejected, result}
        send(parent, {:checked, result})
      end)

    code = AgentLink.AgentSocketProtocol.close_code(:instance_too_long)
    assert_receive {:checked, {:stop, :normal, {^code, ^reason}, _other}}
    assert log =~ "uplink rejected name=lab instance id is too long"
    assert AgentLink.Registry.pid("lab") == holder
    assert named.name == "lab"
    refute_received :superseded
  end
end
