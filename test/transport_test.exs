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

  alias AgentLink.FakeTransport
  alias AgentLink.Transport.WebSocket

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
    assert_receive {:transport_closed, 1001, "gone"}, 1_000

    :ok = WebSocket.send_message(ctx.transport, %{"n" => 2})
    :ok = WebSocket.send_message(ctx.transport, %{"n" => 3})
    sync(ctx.transport)

    :ok = WebSocket.reconnect(ctx.transport, ctx.url)
    assert_receive {:dial, dial}, 1_000
    assert dial.path == "/agent"
    assert_receive {:socket, _socket}, 1_000
    assert_receive {:received, second}, 1_000
    assert_receive {:received, third}, 1_000
    assert AgentLink.Frame.decode(second) == {:ok, %{"n" => 2}}
    assert AgentLink.Frame.decode(third) == {:ok, %{"n" => 3}}
    refute_received {:received, _}
    refute_received {:transport_closed, _, _}
  end

  test "hold cancels a scheduled dial" do
    ctx = start_transport(backoff: 60_000)
    send(ctx.socket, {:close, 1001, "gone"})
    assert_receive {:transport_closed, 1001, "gone"}, 1_000

    :ok = WebSocket.hold(ctx.transport)
    state = sync(ctx.transport)
    assert state.held == true
    assert state.timer == nil
  end

  test "a close reconnects after the backoff" do
    ctx = start_transport()
    send(ctx.socket, {:close, 1001, "going away"})
    assert_receive {:transport_closed, 1001, _}, 1_000
    assert_receive {:dial, dial}, 1_000
    assert dial.path == "/agent"
    assert Process.alive?(ctx.transport)
  end

  test "an empty close reason is delivered" do
    ctx = start_transport(backoff: 60_000)
    send(ctx.socket, {:close, 4004, ""})
    assert_receive {:transport_closed, 4004, ""}, 1_000
    refute_received {:transport_closed, _, _}
  end

  test "reconnect dials the new url and clears a hold" do
    ctx = start_transport(backoff: 60_000)
    :ok = WebSocket.hold(ctx.transport)
    send(ctx.socket, {:close, 4002, "too long"})
    assert_receive {:transport_closed, 4002, "too long"}, 1_000

    :ok = WebSocket.reconnect(ctx.transport, ctx.other_url)
    assert_receive {:dial, dial}, 1_000
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
    await_queue(ctx.transport, fn len -> len >= 1 end)
    queued = queue_len(ctx.transport)
    send(ctx.socket, {:close, 1001, "queued"})
    await_queue(ctx.transport, fn len -> len > queued end)
    :sys.resume(ctx.transport)

    assert Task.await(task) == :ok
    assert_receive {:dial, dial}, 1_000
    assert dial.path == "/moved"
    refute_received {:transport_closed, _, _}
  end

  test "a socket that dies without a close frame is code 1006" do
    ctx = start_transport()

    ExUnit.CaptureLog.capture_log(fn ->
      send(ctx.socket, :drop)
      assert_receive {:transport_closed, 1006, "socket closed"}, 1_000
      refute_received {:transport_closed, _, _}
      assert_receive {:dial, _dial}, 1_000
    end)

    assert Process.alive?(ctx.transport)
  end

  test "the websocket answers a ping with a pong" do
    ctx = start_transport()
    send(ctx.socket, {:push, {:ping, "z"}})
    assert_receive {:pong, "z"}, 1_000
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

    assert_receive {:transport_closed, 1002, _reason}, 1_000
    state = sync(transport)
    assert state.websocket == nil
    assert state.conn == nil
    assert state.held == false
    assert state.timer != nil
  end

  test "endpoint/2 keeps ws plain and wss on TLS" do
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
    assert_receive {:transport_closed, 4004, ""}
    assert FakeTransport.deliver(transport, %{"method" => "late"}) == :closed
    assert FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}]

    :ok = FakeTransport.send_message(transport, %{"n" => 3})
    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/moved")
    assert FakeTransport.sent(transport) == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
    refute_received {:transport_closed, _, _}
  end

  test "FakeTransport hold cancels a scheduled dial" do
    transport = start_fake(backoff: 60_000)
    :ok = FakeTransport.disconnect(transport, 1001, "gone")
    assert_receive {:transport_closed, 1001, "gone"}

    :ok = FakeTransport.hold(transport)
    state = sync(transport)
    assert state.held == true
    assert state.timer == nil

    :ok = FakeTransport.send_message(transport, %{"n" => 1})
    assert FakeTransport.sent(transport) == []
    :ok = FakeTransport.reconnect(transport, "ws://127.0.0.1:9/agent")
    assert FakeTransport.sent(transport) == [%{"n" => 1}]
    assert sync(transport).held == false
  end

  defp start_transport(opts \\ []) do
    parent = self()
    path = Keyword.get(opts, :path, "/agent")
    port = start_bandit(parent)
    other = start_bandit(parent)

    transport_opts = [owner: parent, url: ws_url(port, path)]
    transport_opts = maybe_put(transport_opts, :backoff, Keyword.get(opts, :backoff, :omit))

    transport_opts =
      maybe_put(transport_opts, :default_path, Keyword.get(opts, :default_path, :omit))

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
    assert_receive {:dial, dial}, 1_000
    assert_receive {:socket, socket}, 1_000
    {dial, socket}
  end

  defp await_queue(pid, pred) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    Stream.repeatedly(fn -> queue_len(pid) end)
    |> Enum.reduce_while(:timeout, fn
      nil, _ ->
        {:halt, :dead}

      len, _ ->
        cond do
          pred.(len) ->
            {:halt, :ok}

          System.monotonic_time(:millisecond) >= deadline ->
            {:halt, :timeout}

          true ->
            Process.sleep(1)
            {:cont, :timeout}
        end
    end)
    |> case do
      :ok -> :ok
      :dead -> flunk("transport exited while waiting")
      :timeout -> flunk("timed out waiting for the transport mailbox")
    end
  end

  defp queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> nil
    end
  end

  defp sync(transport), do: :sys.get_state(transport)
end
