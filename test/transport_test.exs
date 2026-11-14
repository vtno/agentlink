defmodule AgentLink.TransportTest.Peer do
  @moduledoc false
  @behaviour WebSock

  @impl true
  def init(spy) do
    send(spy, {:socket, self()})
    {:ok, spy}
  end

  @impl true
  def handle_in({payload, opts}, spy) do
    if Keyword.get(opts, :opcode) in [:text, :binary] do
      send(spy, {:received, IO.iodata_to_binary(payload)})
    end

    {:ok, spy}
  end

  @impl true
  def handle_control({payload, opts}, spy) do
    case Keyword.get(opts, :opcode) do
      :pong -> send(spy, {:pong, payload})
      :ping -> send(spy, {:ping, IO.iodata_to_binary(payload)})
      _opcode -> :ok
    end

    {:ok, spy}
  end

  @impl true
  def handle_info({:push, frame}, spy), do: {:push, [frame], spy}

  def handle_info({:close, code, reason}, spy), do: {:stop, :normal, {code, reason}, spy}

  # Kill the handler so the client sees a TCP drop, not a close frame.
  def handle_info(:drop, _spy), do: Process.exit(self(), :kill)

  def handle_info(_message, spy), do: {:ok, spy}
end

defmodule AgentLink.TransportTest.PeerPlug do
  @moduledoc false

  def init(spy), do: spy

  def call(conn, spy) do
    send(spy, {:dial, dial(conn)})

    conn
    |> WebSockAdapter.upgrade(AgentLink.TransportTest.Peer, spy, timeout: :infinity)
    |> Plug.Conn.halt()
  end

  defp dial(conn) do
    %{
      path: conn.request_path,
      authorization: Plug.Conn.get_req_header(conn, "authorization"),
      x_test: Plug.Conn.get_req_header(conn, "x-test")
    }
  end
end

defmodule AgentLink.TransportTest.Scheduler do
  @moduledoc false
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def send_after(destination, message, delay) do
    ref = make_ref()
    Agent.update(__MODULE__, &Map.put(&1, ref, {destination, message, delay}))
    ref
  end

  def cancel_timer(ref), do: Agent.get_and_update(__MODULE__, &Map.pop(&1, ref))

  def scheduled(ref), do: Agent.get(__MODULE__, &Map.get(&1, ref))

  def fire(ref) do
    {destination, message, _delay} = Agent.get_and_update(__MODULE__, &Map.pop(&1, ref))
    send(destination, message)
    :ok
  end
end

defmodule AgentLink.TransportTest do
  use ExUnit.Case, async: false

  alias AgentLink.FakeTransport
  alias AgentLink.Transport.WebSocket
  alias AgentLink.TransportTest.Scheduler

  test "sends and receives one decoded object" do
    ctx = start_transport()
    assert ctx.dial.authorization == ["Bearer sekret"]
    assert ctx.dial.path == "/agent"
    assert ctx.dial.x_test == []

    :ok = WebSocket.send_message(ctx.transport, %{"method" => "ping"})
    assert_receive {:received, payload}, 1_000
    assert AgentLink.Frame.decode(payload) == {:ok, %{"method" => "ping"}}
    refute String.ends_with?(payload, "\n")

    send(ctx.socket, {:push, {:text, AgentLink.Frame.encode(%{"method" => "pong"})}})
    assert_receive {:from_plane, %{"method" => "pong"}}, 1_000

    send(ctx.socket, {:push, {:binary, AgentLink.Frame.encode(%{"method" => "bin"})}})
    assert_receive {:from_plane, %{"method" => "bin"}}, 1_000

    send(ctx.socket, {:push, {:text, "not-json"}})
    send(ctx.socket, {:push, {:text, "[1]"}})
    send(ctx.socket, {:push, {:text, AgentLink.Frame.encode(%{"method" => "next"})}})
    assert_receive {:from_plane, %{"method" => "next"}}, 1_000
    refute_received {:from_plane, _}
  end

  test "omitted headers use the configured bearer token" do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")
    on_exit(fn -> AgentLink.TestHelpers.restore(:master_token, previous) end)

    ctx = start_transport(headers: :default)
    assert ctx.dial.authorization == ["Bearer sekret"]
  end

  test "explicit headers are sent on the dial" do
    ctx = start_transport(headers: [{"x-test", "yes"}])
    assert ctx.dial.authorization == []
    assert ctx.dial.x_test == ["yes"]
  end

  test "the dial path comes from the url, otherwise default_path" do
    for opts <- [
          [path: "/agent", default_path: "/acp", expect: "/agent"],
          [path: nil, default_path: "/acp", expect: "/acp"],
          [path: nil, expect: "/agent"]
        ] do
      ctx = start_transport(opts)
      assert ctx.dial.path == opts[:expect]
    end
  end

  test "a close keeps later messages queued until reconnect" do
    ctx = start_transport(backoff: 60_000)
    :ok = WebSocket.send_message(ctx.transport, %{"n" => 1})
    assert_receive {:received, first}, 1_000
    assert AgentLink.Frame.decode(first) == {:ok, %{"n" => 1}}

    send(ctx.socket, {:close, 1001, "gone"})
    assert await_closed() == {1001, "gone"}

    :ok = WebSocket.send_message(ctx.transport, %{"n" => 2})
    :ok = WebSocket.send_message(ctx.transport, %{"n" => 3})
    sync(ctx.transport)

    :ok = WebSocket.reconnect(ctx.transport, ctx.url)
    dial = await_dial()
    assert dial.path == "/agent"
    await_socket()
    second = await_payload()
    third = await_payload()
    assert AgentLink.Frame.decode(second) == {:ok, %{"n" => 2}}
    assert AgentLink.Frame.decode(third) == {:ok, %{"n" => 3}}
    refute_received {:received, _}
    refute_received {:transport_closed, _, _}
  end

  test "hold cancels a scheduled dial" do
    start_supervised!(Scheduler)
    ctx = start_transport(backoff: 60_000, scheduler: Scheduler)
    send(ctx.socket, {:close, 1001, "gone"})
    assert await_closed() == {1001, "gone"}
    timer = sync(ctx.transport).timer
    assert Scheduler.scheduled(timer) != nil

    :ok = WebSocket.hold(ctx.transport)
    state = sync(ctx.transport)
    assert state.held == true
    assert state.timer == nil
    assert Scheduler.scheduled(timer) == nil
  end

  test "a close schedules a reconnect with the configured backoff" do
    start_supervised!(Scheduler)
    ctx = start_transport(backoff: 60_000, scheduler: Scheduler)
    send(ctx.socket, {:close, 1001, "going away"})
    assert {1001, _reason} = await_closed()
    state = sync(ctx.transport)
    assert state.backoff == 60_000
    assert is_reference(state.connect_token)

    assert Scheduler.scheduled(state.timer) ==
             {ctx.transport, {:connect, state.connect_token}, 60_000}

    refute_received {:dial, _}
    :ok = Scheduler.fire(state.timer)
    dial = await_dial()
    assert dial.path == "/agent"
    assert Process.alive?(ctx.transport)
  end

  test "an empty close reason is delivered" do
    ctx = start_transport(backoff: 60_000)
    send(ctx.socket, {:close, 4004, ""})
    assert await_closed() == {4004, ""}
    refute_received {:transport_closed, _, _}
  end

  test "url/2 replaces the next dial and leaves the socket, timer, and hold" do
    ctx = start_transport(backoff: 60_000)
    open = sync(ctx.transport)
    assert open.conn != nil
    assert open.timer == nil
    assert open.held == false

    :ok = WebSocket.url(ctx.transport, ctx.other_url)
    moved = sync(ctx.transport)
    assert moved.url == ctx.other_url
    assert moved.conn == open.conn
    assert moved.websocket == open.websocket
    assert moved.ref == open.ref
    assert moved.timer == nil
    assert moved.held == false
    refute_received {:transport_closed, _, _}
    refute_received {:dial, _}

    :ok = WebSocket.send_message(ctx.transport, %{"n" => 1})
    assert_receive {:received, payload}, 1_000
    assert AgentLink.Frame.decode(payload) == {:ok, %{"n" => 1}}

    send(ctx.socket, {:close, 1001, "gone"})
    assert await_closed() == {1001, "gone"}
    waiting = sync(ctx.transport)
    assert waiting.timer != nil
    assert waiting.conn == nil

    :ok = WebSocket.url(ctx.transport, ctx.url)
    retargeted = sync(ctx.transport)
    assert retargeted.url == ctx.url
    assert retargeted.timer == waiting.timer
    assert retargeted.held == false
    assert retargeted.conn == nil
    refute_received {:dial, _}

    :ok = WebSocket.hold(ctx.transport)
    :ok = WebSocket.url(ctx.transport, ctx.other_url)
    held = sync(ctx.transport)
    assert held.url == ctx.other_url
    assert held.held == true
    assert held.timer == nil
    assert held.conn == nil
    refute_received {:dial, _}
  end

  test "reconnect dials the new url and clears a hold" do
    ctx = start_transport(backoff: 60_000)
    :ok = WebSocket.hold(ctx.transport)
    send(ctx.socket, {:close, 4002, "too long"})
    assert await_closed() == {4002, "too long"}

    :ok = WebSocket.reconnect(ctx.transport, ctx.other_url)
    dial = await_dial()
    assert dial.path == "/moved"
    refute_received {:transport_closed, _, _}
  end

  test "reconnect closes the old socket before a queued close frame" do
    ctx = start_transport(backoff: 60_000)
    :sys.suspend(ctx.transport)

    on_exit(fn ->
      if Process.alive?(ctx.transport) do
        try do
          :sys.resume(ctx.transport)
        catch
          _, _ -> :ok
        end
      end
    end)

    task = Task.async(fn -> WebSocket.reconnect(ctx.transport, ctx.other_url) end)

    await_message(ctx.transport, fn messages ->
      Enum.any?(messages, &match?({:"$gen_call", _, {:reconnect, _}}, &1))
    end)

    queued = queue_len(ctx.transport)
    send(ctx.socket, {:close, 1001, "queued"})
    await_queue(ctx.transport, fn len -> len > queued end)
    :sys.resume(ctx.transport)

    assert Task.await(task, :infinity) == :ok
    dial = await_dial()
    assert dial.path == "/moved"
    refute_received {:transport_closed, _, _}
  end

  test "a socket that dies without a close frame is code 1006" do
    ctx = start_transport()

    ExUnit.CaptureLog.capture_log(fn ->
      send(ctx.socket, :drop)
      assert await_closed() == {1006, "socket closed"}
      refute_received {:transport_closed, _, _}
      await_dial()
    end)

    assert Process.alive?(ctx.transport)
  end

  test "a preface leads every dial" do
    preface = %{"method" => "agentlink.uplink", "params" => %{"name" => "opencode"}}
    ctx = start_transport(preface: preface, backoff: 60_000)
    assert_receive {:received, first}, 1_000
    assert AgentLink.Frame.decode(first) == {:ok, preface}

    :ok = WebSocket.send_message(ctx.transport, %{"n" => 1})
    assert_receive {:received, second}, 1_000
    assert AgentLink.Frame.decode(second) == {:ok, %{"n" => 1}}

    next = %{"method" => "agentlink.uplink", "params" => %{"name" => "other"}}
    :ok = WebSocket.preface(ctx.transport, next)
    :ok = WebSocket.reconnect(ctx.transport, ctx.url)
    dial = await_dial()
    assert dial.path == "/agent"
    await_socket()
    third = await_payload()
    assert AgentLink.Frame.decode(third) == {:ok, next}
    refute_received {:received, _}
    refute_received {:transport_closed, _, _}
  end

  test "the websocket answers a ping with a pong" do
    ctx = start_transport()
    send(ctx.socket, {:push, {:ping, "z"}})
    assert_receive {:pong, "z"}, 1_000
  end

  test "a keepalive tick sends a ping" do
    start_supervised!(Scheduler)
    ctx = start_transport(scheduler: Scheduler, ping_interval: 30_000, pong_timeout: 10_000)
    state = sync(ctx.transport)

    assert Scheduler.scheduled(state.ping_timer) ==
             {ctx.transport, {:keepalive_ping, state.ref}, 30_000}

    :ok = Scheduler.fire(state.ping_timer)
    assert_receive {:ping, ""}, 1_000
    refute_received {:transport_closed, _, _}
  end

  test "a pong clears the keepalive deadline" do
    start_supervised!(Scheduler)
    ctx = start_transport(scheduler: Scheduler, ping_interval: 30_000, pong_timeout: 10_000)
    suspend(ctx.socket)

    :ok = Scheduler.fire(sync(ctx.transport).ping_timer)
    armed = sync(ctx.transport)

    assert Scheduler.scheduled(armed.pong_timer) ==
             {ctx.transport, {:keepalive_expired, armed.ref}, 10_000}

    :sys.resume(ctx.socket)
    assert_receive {:ping, ""}, 1_000
    await_cleared(ctx.transport)
    cleared = sync(ctx.transport)
    assert cleared.pong_timer == nil
    assert cleared.ref == armed.ref
    assert cleared.websocket != nil

    send(ctx.transport, {:keepalive_expired, cleared.ref})
    still = sync(ctx.transport)
    assert still.ref == cleared.ref
    assert still.websocket != nil
    refute_received {:transport_closed, _, _}

    :ok = WebSocket.send_message(ctx.transport, %{"n" => 1})
    assert_receive {:received, payload}, 1_000
    assert AgentLink.Frame.decode(payload) == {:ok, %{"n" => 1}}
  end

  test "a missed pong fails the socket and schedules another dial" do
    start_supervised!(Scheduler)

    ctx =
      start_transport(
        scheduler: Scheduler,
        backoff: 60_000,
        ping_interval: 30_000,
        pong_timeout: 10_000
      )

    suspend(ctx.socket)
    :ok = Scheduler.fire(sync(ctx.transport).ping_timer)
    armed = sync(ctx.transport)
    next_ping = armed.ping_timer
    assert Scheduler.scheduled(armed.pong_timer) != nil
    assert Scheduler.scheduled(next_ping) != nil

    :ok = Scheduler.fire(armed.pong_timer)
    failed = sync(ctx.transport)
    assert await_closed() == {1006, "keepalive pong timeout"}
    assert failed.conn == nil
    assert failed.websocket == nil
    assert failed.ping_timer == nil
    assert failed.pong_timer == nil
    assert Scheduler.scheduled(next_ping) == nil
    assert Scheduler.scheduled(armed.pong_timer) == nil

    assert Scheduler.scheduled(failed.timer) ==
             {ctx.transport, {:connect, failed.connect_token}, 60_000}

    :ok = Scheduler.fire(failed.timer)
    assert await_dial().path == "/agent"
    await_socket()
    assert sync(ctx.transport).websocket != nil
    refute_received {:transport_closed, _, _}
  end

  test "a keepalive timer from the previous socket is ignored" do
    start_supervised!(Scheduler)

    ctx =
      start_transport(
        scheduler: Scheduler,
        backoff: 60_000,
        ping_interval: 30_000,
        pong_timeout: 10_000
      )

    old = sync(ctx.transport)
    :ok = WebSocket.reconnect(ctx.transport, ctx.url)
    assert await_dial().path == "/agent"
    await_socket()
    refute_received {:transport_closed, _, _}

    up = sync(ctx.transport)
    assert up.ref != old.ref
    assert up.websocket != nil
    assert Scheduler.scheduled(old.ping_timer) == nil

    assert Scheduler.scheduled(up.ping_timer) ==
             {ctx.transport, {:keepalive_ping, up.ref}, 30_000}

    send(ctx.transport, {:keepalive_ping, old.ref})
    send(ctx.transport, {:keepalive_expired, old.ref})
    kept = sync(ctx.transport)
    assert kept.ref == up.ref
    assert kept.websocket != nil
    assert kept.ping_timer == up.ping_timer
    assert kept.pong_timer == nil
    refute_received {:transport_closed, _, _}

    :ok = WebSocket.send_message(ctx.transport, %{"n" => 1})
    assert_receive {:received, payload}, 1_000
    assert AgentLink.Frame.decode(payload) == {:ok, %{"n" => 1}}
  end

  test "keepalive timings follow opts, then the environment, then application config" do
    start_supervised!(Scheduler)

    previous = %{
      interval: Application.get_env(:agent_link, :websocket_ping_interval),
      timeout: Application.get_env(:agent_link, :websocket_pong_timeout),
      interval_env: System.get_env("AGENTLINK_WEBSOCKET_PING_INTERVAL"),
      timeout_env: System.get_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT")
    }

    on_exit(fn ->
      restore_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", previous.interval_env)
      restore_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT", previous.timeout_env)
      AgentLink.TestHelpers.restore(:websocket_ping_interval, previous.interval)
      AgentLink.TestHelpers.restore(:websocket_pong_timeout, previous.timeout)
    end)

    System.delete_env("AGENTLINK_WEBSOCKET_PING_INTERVAL")
    System.delete_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT")
    Application.delete_env(:agent_link, :websocket_ping_interval)
    Application.delete_env(:agent_link, :websocket_pong_timeout)

    defaults = sync(start_transport(scheduler: Scheduler).transport)
    assert defaults.ping_interval == 30_000
    assert defaults.pong_timeout == 10_000
    assert ping_delay(defaults) == 30_000

    Application.put_env(:agent_link, :websocket_ping_interval, 45_000)
    Application.put_env(:agent_link, :websocket_pong_timeout, 9_000)
    configured = sync(start_transport(scheduler: Scheduler).transport)
    assert configured.ping_interval == 45_000
    assert configured.pong_timeout == 9_000

    System.put_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", "12000")
    System.put_env("AGENTLINK_WEBSOCKET_PONG_TIMEOUT", "4000")
    from_env = sync(start_transport(scheduler: Scheduler).transport)
    assert from_env.ping_interval == 12_000
    assert from_env.pong_timeout == 4_000

    from_opts =
      sync(
        start_transport(scheduler: Scheduler, ping_interval: 15_000, pong_timeout: 5_000).transport
      )

    assert from_opts.ping_interval == 15_000
    assert from_opts.pong_timeout == 5_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        System.put_env("AGENTLINK_WEBSOCKET_PING_INTERVAL", "nope")
        fallen = sync(start_transport(scheduler: Scheduler).transport)
        assert fallen.ping_interval == 45_000
        assert fallen.pong_timeout == 4_000
      end)

    assert log =~ "AGENTLINK_WEBSOCKET_PING_INTERVAL"
    assert log =~ "nope"
  end

  test "a linux dial sets TCP_USER_TIMEOUT to the interval plus the pong timeout" do
    ctx = start_transport(ping_interval: 20_000, pong_timeout: 5_000)
    state = sync(ctx.transport)
    socket = Mint.HTTP.get_socket(state.conn)

    case :os.type() do
      {:unix, :linux} ->
        assert {:ok, opts} = :inet.getopts(socket, [:user_timeout, :keepalive])
        assert opts[:user_timeout] == 25_000
        assert opts[:keepalive] == false

      _other ->
        assert state.websocket != nil
    end
  end

  test "a frame written with the 101 is delivered" do
    payload = AgentLink.Frame.encode(%{"method" => "early"})
    port = start_raw_plane(text_frame(payload))

    start_supervised!(
      {WebSocket,
       [
         owner: self(),
         url: "ws://127.0.0.1:#{port}/agent",
         headers: [{"authorization", "Bearer sekret"}]
       ]}
    )

    assert_receive {:from_plane, %{"method" => "early"}}, 1_000
  end

  test "a malformed frame closes with 1002 and queues another dial" do
    port = start_raw_plane(<<0x83, 0x00>>)

    transport =
      start_supervised!(
        {WebSocket,
         [
           owner: self(),
           url: "ws://127.0.0.1:#{port}/agent",
           headers: [{"authorization", "Bearer sekret"}],
           backoff: 60_000
         ]}
      )

    assert {1002, reason} = await_closed()
    refute reason == "closed"
    state = sync(transport)
    assert state.conn == nil
    assert state.timer != nil
  end

  test "endpoint/2 keeps ws plain and wss on TLS" do
    assert AgentLink.Transport.endpoint("ws://127.0.0.1:8090/agent", "/acp") ==
             {:ws, :http, "127.0.0.1", 8090, "/agent"}

    assert AgentLink.Transport.endpoint("ws://127.0.0.1/agent", "/acp") ==
             {:ws, :http, "127.0.0.1", 80, "/agent"}

    assert AgentLink.Transport.endpoint("ws://127.0.0.1", "/acp") ==
             {:ws, :http, "127.0.0.1", 80, "/acp"}

    assert AgentLink.Transport.endpoint("wss://plane.example/agent", "/acp") ==
             {:wss, :https, "plane.example", 443, "/agent"}

    assert AgentLink.Transport.endpoint("wss://plane.example:8443/agent", "/acp") ==
             {:wss, :https, "plane.example", 8443, "/agent"}

    assert AgentLink.Transport.endpoint("wss://plane.example", "/acp") ==
             {:wss, :https, "plane.example", 443, "/acp"}

    assert AgentLink.Transport.endpoint("ws://127.0.0.1:8090/agent?token=sekret", "/acp") ==
             {:ws, :http, "127.0.0.1", 8090, "/agent"}
  end

  test "FakeTransport queues while down and flushes in order" do
    transport = start_fake(accept: false, backoff: 60_000)

    :ok = FakeTransport.send_message(transport, %{"n" => 1})
    :ok = FakeTransport.send_message(transport, %{"n" => 2})
    assert FakeTransport.sent(transport) == []
    assert FakeTransport.deliver(transport, %{"method" => "early"}) == :closed
    refute_received {:from_plane, _}

    :ok = FakeTransport.allow(transport)
    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/acp")
    assert FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}]

    :ok = FakeTransport.deliver(transport, %{"method" => "yo"})
    assert_receive {:from_plane, %{"method" => "yo"}}

    :ok = FakeTransport.disconnect(transport, 4004, "")
    assert await_closed() == {4004, ""}
    assert FakeTransport.deliver(transport, %{"method" => "late"}) == :closed
    assert FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}]

    :ok = FakeTransport.send_message(transport, %{"n" => 3})
    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/moved")
    assert FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
    refute_received {:transport_closed, _, _}
  end

  test "preface is sent before a queued outbox on each dial" do
    transport =
      start_fake(accept: false, backoff: 60_000, preface: %{"method" => "agentlink.uplink"})

    :ok = FakeTransport.send_message(transport, %{"n" => 1})
    :ok = FakeTransport.send_message(transport, %{"n" => 2})
    assert FakeTransport.sent(transport) == []

    :ok = FakeTransport.allow(transport)
    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/acp")

    assert FakeTransport.sent(transport) == [
             %{"method" => "agentlink.uplink"},
             %{"n" => 1},
             %{"n" => 2}
           ]

    :ok =
      FakeTransport.preface(transport, %{
        "method" => "agentlink.uplink",
        "params" => %{"name" => "other"}
      })

    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/moved")

    assert List.last(FakeTransport.sent(transport)) == %{
             "method" => "agentlink.uplink",
             "params" => %{"name" => "other"}
           }
  end

  test "FakeTransport complete_dial finishes a peer close without waiting" do
    transport = start_fake(backoff: 60_000, preface: %{"method" => "agentlink.uplink"})
    assert FakeTransport.sent(transport) == [%{"method" => "agentlink.uplink"}]

    :ok = FakeTransport.disconnect(transport, 1001, "going away")
    assert await_closed() == {1001, "going away"}
    assert FakeTransport.deliver(transport, %{"n" => 1}) == :closed
    assert FakeTransport.sent(transport) == [%{"method" => "agentlink.uplink"}]

    :ok = FakeTransport.send_message(transport, %{"n" => 2})
    :ok = FakeTransport.complete_dial(transport)

    assert FakeTransport.sent(transport) == [
             %{"method" => "agentlink.uplink"},
             %{"method" => "agentlink.uplink"},
             %{"n" => 2}
           ]

    assert FakeTransport.deliver(transport, %{"n" => 3}) == :ok
    assert_receive {:from_plane, %{"n" => 3}}
  end

  test "FakeTransport hold cancels a scheduled dial" do
    transport = start_fake(backoff: 60_000)
    :ok = FakeTransport.disconnect(transport, 1001, "gone")
    assert await_closed() == {1001, "gone"}

    :ok = FakeTransport.hold(transport)
    :ok = FakeTransport.send_message(transport, %{"n" => 1})
    assert FakeTransport.sent(transport) == []
    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/agent")
    assert FakeTransport.sent(transport) == [%{"n" => 1}]
  end

  defp start_transport(opts \\ []) do
    parent = self()
    path = Keyword.get(opts, :path, "/agent")
    port = start_bandit(parent)
    other = start_bandit(parent)

    transport_opts = [owner: parent, url: ws_url(port, path)]
    transport_opts = maybe_put(transport_opts, :backoff, Keyword.get(opts, :backoff, :omit))
    transport_opts = maybe_put(transport_opts, :scheduler, Keyword.get(opts, :scheduler, :omit))

    transport_opts =
      maybe_put(transport_opts, :default_path, Keyword.get(opts, :default_path, :omit))

    transport_opts = maybe_put(transport_opts, :preface, Keyword.get(opts, :preface, :omit))

    transport_opts =
      maybe_put(transport_opts, :ping_interval, Keyword.get(opts, :ping_interval, :omit))

    transport_opts =
      maybe_put(transport_opts, :pong_timeout, Keyword.get(opts, :pong_timeout, :omit))

    transport_opts =
      case Keyword.get(opts, :headers, [{"authorization", "Bearer sekret"}]) do
        :default -> transport_opts
        headers -> Keyword.put(transport_opts, :headers, headers)
      end

    transport =
      start_supervised!(%{
        id: {WebSocket, System.unique_integer([:positive])},
        start: {WebSocket, :start_link, [transport_opts]},
        restart: :temporary
      })

    {dial, socket} = await_peer()

    %{
      transport: transport,
      url: ws_url(port, path),
      other_url: ws_url(other, "/moved"),
      dial: dial,
      socket: socket
    }
  end

  defp start_fake(opts) do
    fake_opts = [
      owner: self(),
      url: "ws://127.0.0.1:9/acp",
      accept: Keyword.get(opts, :accept, true),
      headers: [{"authorization", "Bearer sekret"}]
    ]

    fake_opts = maybe_put(fake_opts, :backoff, Keyword.get(opts, :backoff, :omit))
    fake_opts = maybe_put(fake_opts, :preface, Keyword.get(opts, :preface, :omit))

    start_supervised!(
      {FakeTransport, fake_opts},
      id: {FakeTransport, System.unique_integer([:positive])}
    )
  end

  defp start_bandit(spy) do
    server =
      start_supervised!(%{
        id: {:peer, System.unique_integer([:positive])},
        start:
          {Bandit, :start_link,
           [
             [
               plug: {AgentLink.TransportTest.PeerPlug, spy},
               scheme: :http,
               port: 0,
               ip: {127, 0, 0, 1}
             ]
           ]},
        restart: :temporary
      })

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # One TCP write: the 101 and `extra` arrive in the same recv, so Mint
  # reports the extra bytes as the upgrade response body.
  defp start_raw_plane(extra) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, request} = read_headers(sock, "")
        :ok = :gen_tcp.send(sock, ws_accept(request) <> extra)

        receive do
          :bye -> :gen_tcp.close(sock)
        end
      end)

    on_exit(fn ->
      send(server, :bye)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 3_000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: read_headers(sock, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ws_accept(request) do
    key = websocket_key(request)

    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "upgrade: websocket\r\n" <>
      "connection: upgrade\r\n" <>
      "sec-websocket-accept: #{accept}\r\n" <>
      "\r\n"
  end

  defp websocket_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "sec-websocket-key", do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload), payload::binary>>
  end

  defp ws_url(port, nil), do: "ws://127.0.0.1:#{port}"
  defp ws_url(port, path), do: "ws://127.0.0.1:#{port}#{path}"

  defp maybe_put(opts, _key, :omit), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp await_peer do
    {await_dial(), await_socket()}
  end

  defp await_closed do
    receive do
      {:transport_closed, code, reason} -> {code, reason}
    end
  end

  defp await_dial do
    receive do
      {:dial, dial} -> dial
    end
  end

  defp await_socket do
    receive do
      {:socket, socket} -> socket
    end
  end

  defp await_payload do
    receive do
      {:received, payload} -> payload
    end
  end

  defp await_message(pid, pred) do
    AgentLink.TestHelpers.await(fn ->
      case mailbox(pid) do
        nil -> flunk("transport exited while waiting")
        messages -> pred.(messages)
      end
    end)
  end

  defp mailbox(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> messages
      nil -> nil
    end
  end

  defp await_queue(pid, pred) do
    AgentLink.TestHelpers.await(fn ->
      case queue_len(pid) do
        nil -> flunk("transport exited while waiting")
        len -> pred.(len)
      end
    end)
  end

  defp queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> nil
    end
  end

  defp sync(transport), do: :sys.get_state(transport)

  defp ping_delay(state) do
    {_dest, _message, delay} = Scheduler.scheduled(state.ping_timer)
    delay
  end

  defp await_cleared(transport) do
    AgentLink.TestHelpers.await(fn -> sync(transport).pong_timer == nil end)
  end

  defp suspend(pid) do
    :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
        catch
          _, _ -> :ok
        end
      end
    end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
