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
    if Keyword.get(opts, :opcode) == :pong, do: send(spy, {:pong, payload})
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

defmodule AgentLink.TransportTest do
  use ExUnit.Case, async: false

  # The same assertions run against the Mint client and the fake.
  for module <- [AgentLink.Transport.WebSocket, AgentLink.FakeTransport] do
    @module module

    describe inspect(@module) do
      test "sends and receives one decoded object" do
        ctx = start_transport(@module)
        assert ctx.dial.authorization == ["Bearer sekret"]
        assert ctx.dial.path == "/agent"
        assert ctx.dial.x_test == []

        :ok = @module.send_message(ctx.transport, %{"method" => "ping"})
        assert_receive {:received, payload}
        assert AgentLink.Frame.decode(payload) == {:ok, %{"method" => "ping"}}
        refute String.ends_with?(payload, "\n")

        send(ctx.socket, {:push, {:text, AgentLink.Frame.encode(%{"method" => "pong"})}})
        assert_receive {:from_plane, %{"method" => "pong"}}

        send(ctx.socket, {:push, {:binary, AgentLink.Frame.encode(%{"method" => "bin"})}})
        assert_receive {:from_plane, %{"method" => "bin"}}

        send(ctx.socket, {:push, {:text, "not-json"}})
        send(ctx.socket, {:push, {:text, "[1]"}})
        refute_receive {:from_plane, _}, 50

        send(ctx.socket, {:push, {:ping, "z"}})
        :ok = @module.send_message(ctx.transport, %{"method" => "out"})
        assert_receive {:received, out}
        assert AgentLink.Frame.decode(out) == {:ok, %{"method" => "out"}}
      end

      test "omitted headers use the configured bearer token" do
        previous = Application.get_env(:agent_link, :master_token)
        Application.put_env(:agent_link, :master_token, "sekret")
        on_exit(fn -> AgentLink.TestHelpers.restore(:master_token, previous) end)

        ctx = start_transport(@module, headers: :default)
        assert ctx.dial.authorization == ["Bearer sekret"]
      end

      test "explicit headers replace the default bearer" do
        previous = Application.get_env(:agent_link, :master_token)
        Application.put_env(:agent_link, :master_token, "sekret")
        on_exit(fn -> AgentLink.TestHelpers.restore(:master_token, previous) end)

        ctx = start_transport(@module, headers: [{"x-test", "yes"}])
        assert ctx.dial.authorization == []
        assert ctx.dial.x_test == ["yes"]
      end

      test "a url path wins over default_path" do
        ctx = start_transport(@module, path: "/agent", default_path: "/acp")
        assert ctx.dial.path == "/agent"
      end

      test "a missing path uses default_path" do
        ctx = start_transport(@module, path: nil, default_path: "/acp")
        assert ctx.dial.path == "/acp"
      end

      test "a missing path dials /agent when default_path is omitted" do
        ctx = start_transport(@module, path: nil)
        assert ctx.dial.path == "/agent"
      end

      test "messages stay queued until the socket is up and then flush in order" do
        ExUnit.CaptureLog.capture_log(fn ->
          ctx = start_transport(@module, down: true, backoff: 60_000)
          :ok = @module.send_message(ctx.transport, %{"n" => 1})
          :ok = @module.send_message(ctx.transport, %{"n" => 2})
          sync(ctx.transport)
          refute_receive {:received, _}, 40

          ctx.listen.()
          :ok = @module.reconnect(ctx.transport, ctx.url)
          assert_receive {:dial, dial}, 1_000
          assert dial.path == "/agent"
          assert_receive {:received, first}
          assert_receive {:received, second}
          assert AgentLink.Frame.decode(first) == {:ok, %{"n" => 1}}
          assert AgentLink.Frame.decode(second) == {:ok, %{"n" => 2}}
          refute_receive {:received, _}, 40
        end)
      end

      test "a close keeps later messages queued until reconnect" do
        ctx = start_transport(@module, backoff: 60_000)
        :ok = @module.send_message(ctx.transport, %{"n" => 1})
        assert_receive {:received, first}
        assert AgentLink.Frame.decode(first) == {:ok, %{"n" => 1}}

        send(ctx.socket, {:close, 1001, "gone"})
        assert_receive {:transport_closed, 1001, "gone"}, 1_000

        :ok = @module.send_message(ctx.transport, %{"n" => 2})
        :ok = @module.send_message(ctx.transport, %{"n" => 3})
        sync(ctx.transport)
        refute_receive {:received, _}, 40

        :ok = @module.reconnect(ctx.transport, ctx.url)
        refute_receive {:transport_closed, _, _}, 40
        assert_receive {:dial, dial}
        assert dial.path == "/agent"
        assert_receive {:received, second}
        assert_receive {:received, third}
        assert AgentLink.Frame.decode(second) == {:ok, %{"n" => 2}}
        assert AgentLink.Frame.decode(third) == {:ok, %{"n" => 3}}
        refute_receive {:received, _}, 40
      end

      test "hold stops the next dial and release starts it" do
        ctx = start_transport(@module, backoff: 200)
        :ok = @module.hold(ctx.transport)
        send(ctx.socket, {:close, 4001, "name taken"})
        assert_receive {:transport_closed, 4001, "name taken"}, 1_000
        refute_receive {:dial, _}, 350
        assert Process.alive?(ctx.transport)

        :ok = @module.release(ctx.transport)
        assert_receive {:dial, dial}, 1_000
        assert dial.path == "/agent"
      end

      test "hold cancels a dial that was already scheduled" do
        ctx = start_transport(@module, backoff: 300)
        send(ctx.socket, {:close, 1001, "gone"})
        assert_receive {:transport_closed, 1001, "gone"}, 1_000
        :ok = @module.hold(ctx.transport)
        refute_receive {:dial, _}, 500
      end

      test "a close reconnects after the backoff" do
        ctx = start_transport(@module, backoff: 400)
        send(ctx.socket, {:close, 1001, "going away"})
        assert_receive {:transport_closed, 1001, "going away"}, 1_000
        refute_receive {:dial, _}, 200
        assert_receive {:dial, dial}, 1_000
        assert dial.path == "/agent"
        assert Process.alive?(ctx.transport)
      end

      test "an empty close reason is delivered" do
        ctx = start_transport(@module, backoff: 60_000)
        send(ctx.socket, {:close, 4004, ""})
        assert_receive {:transport_closed, 4004, ""}, 1_000
        refute_receive {:transport_closed, _, _}, 40
        refute_receive {:dial, _}, 40
      end

      test "reconnect dials the new url and clears a hold" do
        ctx = start_transport(@module, backoff: 60_000)
        :ok = @module.hold(ctx.transport)
        send(ctx.socket, {:close, 4002, "too long"})
        assert_receive {:transport_closed, 4002, "too long"}, 1_000
        refute_receive {:dial, _}, 40

        :ok = @module.reconnect(ctx.transport, ctx.other_url)
        assert_receive {:dial, dial}, 1_000
        assert dial.path == "/moved"
        refute_receive {:transport_closed, _, _}, 40
      end

      test "release leaves an open socket up" do
        ctx = start_transport(@module, backoff: 60_000)
        :ok = @module.hold(ctx.transport)
        :ok = @module.release(ctx.transport)
        refute_receive {:transport_closed, _, _}, 40
        refute_receive {:dial, _}, 40

        :ok = @module.send_message(ctx.transport, %{"method" => "still"})
        assert_receive {:received, payload}
        assert AgentLink.Frame.decode(payload) == {:ok, %{"method" => "still"}}
      end

      test "a socket that dies without a close frame is code 1006" do
        ctx = start_transport(@module, backoff: 50)

        ExUnit.CaptureLog.capture_log(fn ->
          send(ctx.socket, :drop)
          assert_receive {:transport_closed, 1006, "socket closed"}, 1_000
          refute_receive {:transport_closed, _, _}, 40
          assert_receive {:dial, _dial}, 1_000
        end)

        assert Process.alive?(ctx.transport)
      end
    end
  end

  test "the websocket answers a ping with a pong" do
    ctx = start_transport(AgentLink.Transport.WebSocket)
    send(ctx.socket, {:push, {:ping, "z"}})
    assert_receive {:pong, "z"}
  end

  test "endpoint/2 keeps ws plain and wss on TLS, and the uplink delegates" do
    assert AgentLink.Transport.endpoint("ws://127.0.0.1:8090/agent", "/acp") ==
             {:ws, :http, "127.0.0.1", 8090, "/agent"}

    assert AgentLink.Transport.endpoint("ws://127.0.0.1/agent", "/acp") ==
             {:ws, :http, "127.0.0.1", 80, "/agent"}

    assert AgentLink.Transport.endpoint("ws://127.0.0.1", "/acp") ==
             {:ws, :http, "127.0.0.1", 80, "/acp"}

    assert AgentLink.Transport.endpoint("http://127.0.0.1:8090/agent", "/agent") ==
             {:ws, :http, "127.0.0.1", 8090, "/agent"}

    assert AgentLink.Transport.endpoint("wss://plane.example/agent", "/acp") ==
             {:wss, :https, "plane.example", 443, "/agent"}

    assert AgentLink.Transport.endpoint("wss://plane.example:8443/agent", "/acp") ==
             {:wss, :https, "plane.example", 8443, "/agent"}

    assert AgentLink.Transport.endpoint("wss://plane.example", "/acp") ==
             {:wss, :https, "plane.example", 443, "/acp"}

    assert AgentLink.Transport.endpoint("https://plane.example/agent", "/agent") ==
             {:wss, :https, "plane.example", 443, "/agent"}

    for url <- [
          "ws://127.0.0.1:8090/agent",
          "ws://127.0.0.1/agent",
          "ws://127.0.0.1",
          "http://127.0.0.1:8090/agent",
          "wss://plane.example/agent",
          "wss://plane.example:8443/agent",
          "wss://plane.example",
          "https://plane.example/agent"
        ] do
      assert AgentLink.Uplink.endpoint(url) == AgentLink.Transport.endpoint(url, "/agent")
    end
  end

  test "FakeTransport deliver, sent, and disconnect speak maps" do
    transport =
      start_supervised!(
        {AgentLink.FakeTransport,
         [
           owner: self(),
           url: "ws://127.0.0.1:9/acp",
           accept: false,
           backoff: 60_000,
           default_path: "/acp",
           headers: [{"authorization", "Bearer sekret"}]
         ]}
      )

    :ok = AgentLink.FakeTransport.send_message(transport, %{"n" => 1})
    :ok = AgentLink.FakeTransport.send_message(transport, %{"n" => 2})
    sync(transport)
    assert AgentLink.FakeTransport.sent(transport) == []
    assert AgentLink.FakeTransport.deliver(transport, %{"method" => "early"}) == :closed
    refute_receive {:from_plane, _}

    :ok = AgentLink.FakeTransport.allow(transport)
    :ok = AgentLink.FakeTransport.reconnect(transport, "ws://127.0.0.1:9/acp")
    assert AgentLink.FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}]

    :ok = AgentLink.FakeTransport.deliver(transport, %{"method" => "yo"})
    assert_receive {:from_plane, %{"method" => "yo"}}

    :ok = AgentLink.FakeTransport.disconnect(transport, 4001, "taken")
    assert_receive {:transport_closed, 4001, "taken"}
    assert AgentLink.FakeTransport.deliver(transport, %{"method" => "late"}) == :closed
    assert AgentLink.FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}]
  end

  defp start_transport(module, opts \\ []) do
    parent = self()
    path = Keyword.get(opts, :path, "/agent")
    down = Keyword.get(opts, :down, false)
    {url, other_url, listen} = open_plane(module, path, down, parent)

    transport_opts = [owner: parent, url: url]
    transport_opts = maybe_put(transport_opts, :backoff, Keyword.get(opts, :backoff, :omit))

    transport_opts =
      maybe_put(transport_opts, :default_path, Keyword.get(opts, :default_path, :omit))

    transport_opts =
      case Keyword.get(opts, :headers, [{"authorization", "Bearer sekret"}]) do
        :default -> transport_opts
        headers -> Keyword.put(transport_opts, :headers, headers)
      end

    transport_opts =
      if module == AgentLink.FakeTransport do
        transport_opts
        |> Keyword.put(:spy, parent)
        |> Keyword.put(:accept, not down)
      else
        transport_opts
      end

    transport =
      start_supervised!(%{
        id: {module, System.unique_integer([:positive])},
        start: {module, :start_link, [transport_opts]},
        restart: :temporary
      })

    listen =
      case {module, down} do
        {AgentLink.FakeTransport, true} -> fn -> AgentLink.FakeTransport.allow(transport) end
        {AgentLink.Transport.WebSocket, true} -> listen
        _ -> fn -> :ok end
      end

    ctx = %{
      module: module,
      transport: transport,
      url: url,
      other_url: other_url,
      listen: listen
    }

    if down do
      ctx
    else
      {dial, socket} = await_peer()
      Map.merge(ctx, %{dial: dial, socket: socket})
    end
  end

  defp open_plane(AgentLink.Transport.WebSocket, path, down, parent) do
    other = start_bandit(parent)
    other_url = ws_url(other, "/moved")

    if down do
      port = free_port()

      listen = fn ->
        start_bandit(parent, port)
        :ok
      end

      {ws_url(port, path), other_url, listen}
    else
      {ws_url(start_bandit(parent), path), other_url, fn -> :ok end}
    end
  end

  defp open_plane(AgentLink.FakeTransport, path, _down, _parent) do
    {ws_url(9, path), ws_url(9, "/moved"), fn -> :ok end}
  end

  defp start_bandit(spy, port \\ 0) do
    server =
      start_supervised!(%{
        id: {:peer, System.unique_integer([:positive])},
        start:
          {Bandit, :start_link,
           [
             [
               plug: {AgentLink.TransportTest.PeerPlug, spy},
               scheme: :http,
               port: port,
               ip: {127, 0, 0, 1}
             ]
           ]},
        restart: :temporary
      })

    if port == 0 do
      {:ok, {_ip, bound}} = ThousandIsland.listener_info(server)
      bound
    else
      port
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp ws_url(port, nil), do: "ws://127.0.0.1:#{port}"
  defp ws_url(port, path), do: "ws://127.0.0.1:#{port}#{path}"

  defp maybe_put(opts, _key, :omit), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp await_peer do
    assert_receive {:dial, dial}, 1_000
    assert_receive {:socket, socket}, 1_000
    {dial, socket}
  end

  defp sync(transport), do: :sys.get_state(transport)
end
