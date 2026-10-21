defmodule Acp.UplinkTest do
  use ExUnit.Case, async: false

  defmodule WsEcho do
    @behaviour WebSock

    @impl true
    def init(owner) do
      send(owner, {:socket, self()})
      {:ok, owner}
    end

    @impl true
    def handle_in({text, [opcode: :text]}, owner) do
      send(owner, {:ws, text})
      {:ok, owner}
    end

    def handle_in(_frame, owner), do: {:ok, owner}

    @impl true
    def handle_info({:push, frame}, owner), do: {:push, [frame], owner}
    def handle_info(_message, owner), do: {:ok, owner}
  end

  defmodule WsPlug do
    def init(owner), do: owner

    def call(conn, owner) do
      conn
      |> WebSockAdapter.upgrade(WsEcho, owner, timeout: :infinity)
      |> Plug.Conn.halt()
    end
  end

  defmodule HttpPlain do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "nope")
  end

  setup do
    previous = System.get_env("ACP_PLANE_URL")

    on_exit(fn ->
      restore("ACP_PLANE_URL", previous)
      if pid = Process.whereis(Acp.Uplink), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  test "a message waits in the outbox while the plane is down" do
    System.put_env("ACP_PLANE_URL", "ws://127.0.0.1:1/agent")
    start_supervised!({Acp.Uplink, owner: self()})
    Acp.Uplink.send_message(%{"method" => "ping"})
    Process.sleep(50)
    assert %{"method" => "ping"} in :sys.get_state(Acp.Uplink).outbox
    send(Acp.Uplink, :nope)
    send(Acp.Uplink, :watch)
    assert Process.alive?(Process.whereis(Acp.Uplink))
  end

  test "a handshake that is not a websocket is retried" do
    start_supervised!({Bandit, plug: HttpPlain, scheme: :http, port: 18_094, ip: {127, 0, 0, 1}})
    System.put_env("ACP_PLANE_URL", "ws://127.0.0.1:18094/agent")
    start_supervised!({Acp.Uplink, owner: self()})
    Process.sleep(200)
    assert Process.alive?(Process.whereis(Acp.Uplink))
    assert :sys.get_state(Acp.Uplink).websocket == nil
  end

  test "a connected uplink sends, receives, and redials when the link changes" do
    start_supervised!({Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_095, ip: {127, 0, 0, 1}})
    System.put_env("ACP_PLANE_URL", "ws://127.0.0.1:18095/agent")
    start_supervised!({Acp.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, hello}
    assert %{"method" => "acp.uplink"} = Jason.decode!(hello)

    send(socket, {:push, {:text, ~s({"jsonrpc":"2.0","method":"ping"})}})
    assert_receive {:from_plane, %{"method" => "ping"}}

    send(socket, {:push, {:binary, ~s({"jsonrpc":"2.0","method":"bin"})}})
    assert_receive {:from_plane, %{"method" => "bin"}}

    send(socket, {:push, {:text, "not-json"}})
    refute_receive {:from_plane, _}, 50

    send(socket, {:push, {:ping, "z"}})
    Acp.Uplink.send_message(%{"method" => "out"})
    assert_receive {:ws, out}
    assert %{"method" => "out"} = Jason.decode!(out)

    System.put_env("ACP_PLANE_URL", "ws://127.0.0.1:1/agent")
    send(Acp.Uplink, :watch)
    Process.sleep(200)
    assert :sys.get_state(Acp.Uplink).websocket == nil
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
