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

  test "a keepalive tick pushes a ping and a pong clears the deadline" do
    start_supervised!(AgentLink.FakeScheduler)
    {:ok, state} = AgentLink.AgentSocket.init({admin(), keepalive_opts()})

    assert AgentLink.FakeScheduler.scheduled(state.keepalive.ping_timer) ==
             {self(), {:keepalive_ping, state.keepalive.ping_token}, 30_000}

    assert {:push, [{:ping, ""}], armed} =
             AgentLink.AgentSocket.handle_info(
               {:keepalive_ping, state.keepalive.ping_token},
               state
             )

    assert AgentLink.FakeScheduler.scheduled(armed.keepalive.pong_timer) ==
             {self(), {:keepalive_expired, armed.keepalive.pong_token}, 10_000}

    token = armed.keepalive.pong_token
    assert {:ok, cleared} = AgentLink.AgentSocket.handle_control({"", [opcode: :pong]}, armed)
    assert cleared.keepalive.pong_token == nil
    assert AgentLink.FakeScheduler.scheduled(armed.keepalive.pong_timer) == nil

    assert {:ok, ^cleared} =
             AgentLink.AgentSocket.handle_info({:keepalive_expired, token}, cleared)

    assert {:ok, ^cleared} = AgentLink.AgentSocket.handle_control({"z", [opcode: :ping]}, cleared)
  end

  test "a missed pong returns the close that exits the socket process" do
    start_supervised!(AgentLink.FakeScheduler)
    {:ok, state} = AgentLink.AgentSocket.init({admin(), keepalive_opts()})

    {:push, _, armed} =
      AgentLink.AgentSocket.handle_info({:keepalive_ping, state.keepalive.ping_token}, state)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:stop, {:shutdown, :keepalive_pong_timeout}, {1001, "keepalive pong timeout"},
                _stopped} =
                 AgentLink.AgentSocket.handle_info(
                   {:keepalive_expired, armed.keepalive.pong_token},
                   armed
                 )
      end)

    assert log =~ "plane keepalive expired"
  end

  test "a superseded socket still stops when a pong deadline is armed" do
    start_supervised!(AgentLink.FakeScheduler)
    {:ok, state} = AgentLink.AgentSocket.init({admin(), keepalive_opts()})
    assert {:ok, named} = AgentLink.AgentSocket.handle_in({hello("lab"), [opcode: :text]}, state)

    assert {:push, [{:ping, ""}], armed} =
             AgentLink.AgentSocket.handle_info(
               {:keepalive_ping, named.keepalive.ping_token},
               named
             )

    assert armed.keepalive.pong_token != nil
    assert {:stop, :normal, ^armed} = AgentLink.AgentSocket.handle_info(:superseded, armed)
  end

  test "a socket reads the same keepalive sources as the dial" do
    start_supervised!(AgentLink.FakeScheduler)
    {:ok, from_config} = AgentLink.AgentSocket.init({admin(), scheduler: AgentLink.FakeScheduler})
    assert from_config.keepalive.interval == 3_600_000
    assert from_config.keepalive.timeout == 3_600_000

    {:ok, from_opts} = AgentLink.AgentSocket.init({admin(), keepalive_opts()})
    assert from_opts.keepalive.interval == 30_000
    assert from_opts.keepalive.timeout == 10_000

    previous = System.get_env("AGENTLINK_WEBSOCKET_PING_INTERVAL")
    on_exit(fn -> restore_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", previous) end)
    System.put_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", "nope")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, fallen} = AgentLink.AgentSocket.init({admin(), scheduler: AgentLink.FakeScheduler})
        assert fallen.keepalive.interval == 3_600_000
      end)

    assert log =~ "plane keepalive AGENTLINK_WEBSOCKET_PING_INTERVAL ignored \"nope\""
  end

  test "a missed pong deregisters the runtime and fails in-flight and queued requests" do
    start_supervised!(AgentLink.FakeScheduler)
    {pid, _state} = AgentLink.SocketLoop.start(AgentLink.AgentSocket, {admin(), keepalive_opts()})
    ref = Process.monitor(pid)
    send(pid, {:in, {hello("lab"), [opcode: :text]}})
    assert AgentLink.TestHelpers.await_pid("lab") == pid

    client = AgentLink.Plane.register(self(), admin())
    AgentLink.Plane.client_frame(client, request(1, "runtime/select", %{"name" => "lab"}))
    assert %{"id" => 1, "result" => %{"name" => "lab"}} = pushed_to_self()

    AgentLink.Plane.client_frame(
      client,
      request("new", "session/new", %{"cwd" => "/tmp", "mcpServers" => []})
    )

    request_to_agent = pushed_json(pid)
    assert request_to_agent["method"] == "session/new"

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => request_to_agent["id"],
        "result" => %{"sessionId" => "ses_1"}
      })
    )

    assert %{"result" => %{"sessionId" => "ses_1"}} = pushed_to_self()

    AgentLink.Plane.client_frame(client, prompt(8))
    assert %{"method" => "session/update"} = pushed_to_self()
    assert %{"method" => "session/prompt"} = pushed_json(pid)

    AgentLink.Plane.client_frame(client, prompt(9))
    _ = :sys.get_state(AgentLink.Plane)
    assert :queue.len(:sys.get_state(AgentLink.Plane).slots["lab"].prompt_queue["ses_1"]) == 1

    state = AgentLink.SocketLoop.state(pid)
    :ok = AgentLink.FakeScheduler.fire(state.keepalive.ping_timer)
    assert_receive {:socket_loop, ^pid, :push, [{:ping, ""}]}
    state = AgentLink.SocketLoop.state(pid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = AgentLink.FakeScheduler.fire(state.keepalive.pong_timer)
        assert AgentLink.TestHelpers.await_down(ref, pid) == :normal
      end)

    assert log =~ "plane keepalive expired"
    assert AgentLink.TestHelpers.await(fn -> AgentLink.Registry.pid("lab") == nil end)
    assert error_ids([8, 9]) == :ok
    assert :sys.get_state(AgentLink.Plane).slots["lab"] == nil
  end

  test "the listening agent socket sends a ping and a missed pong drops it from status" do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")

    on_exit(fn ->
      AgentLink.TestHelpers.restore(:master_token, previous)
    end)

    start_supervised!(
      {Bandit, plug: AgentLink.Router, scheme: :http, port: 18_092, ip: {127, 0, 0, 1}}
    )

    assert {:ok, conn, ref, websocket} =
             upgrade(18_092, "/agent", [{"authorization", "Bearer sekret"}])

    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, hello("lab")})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :active)
    pid = AgentLink.TestHelpers.await_pid("lab")
    mon = Process.monitor(pid)
    keepalive = plane_keepalive(pid)

    send(pid, {:keepalive_ping, keepalive.ping_token})
    {conn, websocket} = await_frame(conn, websocket, {:ping, ""})
    armed = plane_keepalive(pid)
    assert armed.pong_token != nil

    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:pong, ""})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    AgentLink.TestHelpers.await(fn -> plane_keepalive(pid).pong_token == nil end)

    send(pid, {:keepalive_expired, armed.pong_token})
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert AgentLink.Registry.pid("lab") == pid

    current = plane_keepalive(pid)
    send(pid, {:keepalive_ping, current.ping_token})
    {conn, websocket} = await_frame(conn, websocket, {:ping, ""})
    expired = plane_keepalive(pid)
    send(pid, {:keepalive_expired, expired.pong_token})
    {frames, reason} = await_close(conn, websocket, mon, pid)

    assert reason == {:shutdown, :keepalive_pong_timeout}
    assert {:close, 1001, "keepalive pong timeout"} in frames
    assert AgentLink.TestHelpers.await(fn -> AgentLink.Registry.pid("lab") == nil end)

    {200, body} = http_get(18_092, "/status", [{"authorization", "Bearer sekret"}])
    assert Jason.decode!(body)["runtimes"] == []
  end

  defp admin, do: %AgentLink.Access.Subject{id: "admin", role: :admin}

  defp keepalive_opts do
    [scheduler: AgentLink.FakeScheduler, ping_interval: 30_000, pong_timeout: 10_000]
  end

  defp hello(name) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "agentlink.uplink",
      "params" => %{"name" => name, "label" => "Bench"}
    })
  end

  defp request(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp prompt(id) do
    request(id, "session/prompt", %{
      "sessionId" => "ses_1",
      "prompt" => [%{"type" => "text", "text" => "go"}]
    })
  end

  defp pushed_json(pid) do
    assert_receive {:socket_loop, ^pid, :push, [{:text, json}]}
    Jason.decode!(json)
  end

  defp pushed_to_self do
    assert_receive {:send, json}
    Jason.decode!(json)
  end

  defp error_ids(ids) do
    Enum.reduce(ids, MapSet.new(ids), fn _, waiting ->
      assert_receive {:send, json}
      message = Jason.decode!(json)
      id = message["id"]
      assert id in waiting
      assert message["error"] == %{"code" => -32000, "message" => "runtime disconnected"}
      MapSet.delete(waiting, id)
    end)

    :ok
  end

  defp plane_keepalive(pid) do
    {_socket, %{connection: %{websock_state: %{keepalive: keepalive}}}} = :sys.get_state(pid)
    keepalive
  end

  defp upgrade(port, path, headers) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)

    with {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
         {:ok, conn, status, headers} <- await_upgrade(conn, ref, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, ref, websocket}
    end
  end

  defp await_upgrade(conn, ref, acc) do
    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      status =
        Enum.find_value(acc, fn
          {:status, ^ref, status} -> status
          _ -> nil
        end)

      headers =
        Enum.find_value(acc, [], fn
          {:headers, ^ref, headers} -> headers
          _ -> nil
        end)

      {:ok, conn, status, headers}
    else
      {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)
      await_upgrade(conn, ref, acc ++ responses)
    end
  end

  defp await_frame(conn, websocket, frame) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {websocket, frames} = decode_frames(websocket, responses)

            if frame in frames do
              {conn, websocket}
            else
              await_frame(conn, websocket, frame)
            end

          :unknown ->
            await_frame(conn, websocket, frame)
        end
    end
  end

  defp await_close(conn, websocket, mon, pid, frames \\ [], reason \\ :pending) do
    if reason != :pending and Enum.any?(frames, &match?({:close, _, _}, &1)) do
      {frames, reason}
    else
      receive do
        {:DOWN, ^mon, :process, ^pid, down_reason} ->
          await_close(conn, websocket, mon, pid, frames, down_reason)

        message ->
          case Mint.WebSocket.stream(conn, message) do
            {:ok, conn, responses} ->
              {websocket, extra} = decode_frames(websocket, responses)
              await_close(conn, websocket, mon, pid, frames ++ extra, reason)

            {:error, _conn, _error, responses} ->
              {_websocket, extra} = decode_frames(websocket, responses)
              finish_close(mon, pid, frames ++ extra, reason)

            :unknown ->
              await_close(conn, websocket, mon, pid, frames, reason)
          end
      end
    end
  end

  defp finish_close(_mon, _pid, frames, reason) when reason != :pending, do: {frames, reason}

  defp finish_close(mon, pid, frames, :pending) do
    {frames, AgentLink.TestHelpers.await_down(mon, pid)}
  end

  defp decode_frames(websocket, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, _ref, data}, {websocket, frames} ->
        {:ok, websocket, extra} = Mint.WebSocket.decode(websocket, data)
        {websocket, frames ++ extra}

      _, acc ->
        acc
    end)
  end

  defp http_get(port, path, headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, headers, nil)
    assert {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)

    status =
      Enum.find_value(responses, fn
        {:status, ^ref, code} -> code
        _ -> nil
      end)

    body =
      Enum.find_value(responses, "", fn
        {:data, ^ref, chunk} -> chunk
        _ -> nil
      end)

    Mint.HTTP.close(conn)
    {status, body}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
