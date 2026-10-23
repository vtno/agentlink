defmodule Pont.UplinkTest do
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

  defmodule AuthPlug do
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end
  end

  defmodule HttpPlain do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "nope")
  end

  setup do
    previous = System.get_env("PONT_PLANE_URL")
    link_path = Application.get_env(:pont, :link_path)
    path = Path.join(System.tmp_dir!(), "pont-uplink-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent"}))
    Application.put_env(:pont, :link_path, path)

    on_exit(fn ->
      restore("PONT_PLANE_URL", previous)
      restore_link(link_path)
      File.rm(path)
      if pid = Process.whereis(Pont.Uplink), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  test "a missing link file stops the uplink" do
    Process.flag(:trap_exit, true)
    missing = "/tmp/pont-uplink-missing-#{System.unique_integer([:positive])}.json"
    Application.put_env(:pont, :link_path, missing)

    assert {:error, {:shutdown, message}} = Pont.Uplink.start_link(owner: self())
    assert message =~ "No link file"
    refute Process.whereis(Pont.Uplink)
  end

  test "a deleted link file stops the uplink on the next dial" do
    pid =
      start_supervised!(%{
        id: Pont.Uplink,
        start: {Pont.Uplink, :start_link, [[owner: self()]]},
        restart: :temporary
      })

    :sys.get_state(pid)
    File.rm!(Application.get_env(:pont, :link_path))
    ref = Process.monitor(pid)
    send(pid, :connect)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, message}}
    assert message =~ "No link file"
    refute Process.whereis(Pont.Uplink)
  end

  test "a deleted link file stops the uplink on the next watch" do
    pid =
      start_supervised!(%{
        id: Pont.Uplink,
        start: {Pont.Uplink, :start_link, [[owner: self()]]},
        restart: :temporary
      })

    :sys.get_state(pid)
    File.rm!(Application.get_env(:pont, :link_path))
    ref = Process.monitor(pid)
    send(pid, :watch)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, message}}
    assert message =~ "No link file"
    refute Process.whereis(Pont.Uplink)
  end

  test "the uplink sends the bearer token when it dials" do
    previous = Application.get_env(:pont, :master_token)
    Application.put_env(:pont, :master_token, "sekret")
    on_exit(fn -> restore_token(previous) end)

    start_supervised!({Bandit, plug: {Pont.UplinkTest.AuthPlug, self()}, scheme: :http, port: 18_093, ip: {127, 0, 0, 1}})
    System.put_env("PONT_PLANE_URL", "ws://127.0.0.1:18093/agent")
    start_supervised!({Pont.Uplink, owner: self()})
    assert_receive {:auth, ["Bearer sekret"]}
  end

  test "a message waits in the outbox while the plane is down" do
    System.put_env("PONT_PLANE_URL", "ws://127.0.0.1:1/agent")
    start_supervised!({Pont.Uplink, owner: self()})
    Pont.Uplink.send_message(%{"method" => "ping"})
    Process.sleep(50)
    assert %{"method" => "ping"} in :sys.get_state(Pont.Uplink).outbox
    send(Pont.Uplink, :nope)
    send(Pont.Uplink, :watch)
    assert Process.alive?(Process.whereis(Pont.Uplink))
  end

  test "a handshake that is not a websocket is retried" do
    start_supervised!({Bandit, plug: HttpPlain, scheme: :http, port: 18_094, ip: {127, 0, 0, 1}})
    System.put_env("PONT_PLANE_URL", "ws://127.0.0.1:18094/agent")
    start_supervised!({Pont.Uplink, owner: self()})
    Process.sleep(200)
    assert Process.alive?(Process.whereis(Pont.Uplink))
    assert :sys.get_state(Pont.Uplink).websocket == nil
  end

  test "a connected uplink sends, receives, and redials when the link changes" do
    start_supervised!({Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_095, ip: {127, 0, 0, 1}})
    System.put_env("PONT_PLANE_URL", "ws://127.0.0.1:18095/agent")
    start_supervised!({Pont.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, hello}
    assert %{"method" => "pont.uplink"} = Jason.decode!(hello)

    send(socket, {:push, {:text, ~s({"jsonrpc":"2.0","method":"ping"})}})
    assert_receive {:from_plane, %{"method" => "ping"}}

    send(socket, {:push, {:binary, ~s({"jsonrpc":"2.0","method":"bin"})}})
    assert_receive {:from_plane, %{"method" => "bin"}}

    send(socket, {:push, {:text, "not-json"}})
    refute_receive {:from_plane, _}, 50

    send(socket, {:push, {:ping, "z"}})
    Pont.Uplink.send_message(%{"method" => "out"})
    assert_receive {:ws, out}
    assert %{"method" => "out"} = Jason.decode!(out)

    System.put_env("PONT_PLANE_URL", "ws://127.0.0.1:1/agent")
    send(Pont.Uplink, :watch)
    Process.sleep(200)
    assert :sys.get_state(Pont.Uplink).websocket == nil
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
  defp restore_link(nil), do: Application.delete_env(:pont, :link_path)
  defp restore_link(path), do: Application.put_env(:pont, :link_path, path)
  defp restore_token(nil), do: Application.delete_env(:pont, :master_token)
  defp restore_token(value), do: Application.put_env(:pont, :master_token, value)
end
