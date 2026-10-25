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
    def handle_info({:close, code, reason}, owner), do: {:stop, :normal, {code, reason}, owner}
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
    link_path = Application.get_env(:pont, :link_path)
    path = Path.join(System.tmp_dir!(), "pont-uplink-#{System.unique_integer([:positive])}.json")
    Application.put_env(:pont, :link_path, path)
    write_link!("ws://127.0.0.1:1/agent")

    on_exit(fn ->
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

    start_supervised!(
      {Bandit,
       plug: {Pont.UplinkTest.AuthPlug, self()}, scheme: :http, port: 18_093, ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:18093/agent")
    start_supervised!({Pont.Uplink, owner: self()})
    assert_receive {:auth, ["Bearer sekret"]}
  end

  test "a message waits in the outbox while the plane is down" do
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
    write_link!("ws://127.0.0.1:18094/agent")
    start_supervised!({Pont.Uplink, owner: self()})
    Process.sleep(200)
    assert Process.alive?(Process.whereis(Pont.Uplink))
    assert :sys.get_state(Pont.Uplink).websocket == nil
  end

  test "a connected uplink sends, receives, and redials when the link changes" do
    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_095, ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:18095/agent")
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

    write_link!("ws://127.0.0.1:1/agent")
    send(Pont.Uplink, :watch)
    Process.sleep(200)
    assert :sys.get_state(Pont.Uplink).websocket == nil
  end

  test "a name-taken close does not redial until the link name changes" do
    url = "ws://127.0.0.1:18111/agent"

    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_111, ip: {127, 0, 0, 1}}
    )

    write_link!(url)
    start_supervised!({Pont.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, hello}
    assert %{"method" => "pont.uplink"} = Jason.decode!(hello)

    reason = Pont.AgentSocket.name_taken_reason("opencode")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(socket, {:close, 4001, reason})
        assert await_name_taken()
      end)

    assert log =~ "uplink rejected name=opencode"
    assert log =~ reason
    assert log =~ "Another relay is already connected with this name"

    assert log =~
             "Stop the other relay and restart this one, or change name in #{Pont.Paths.link()}"

    assert log =~ "will not reconnect until name or plane_url changes"

    send(Pont.Uplink, :connect)
    write_link!(url, %{"label" => "other label"})
    send(Pont.Uplink, :watch)
    refute_receive {:socket, _}, 1_000

    state = :sys.get_state(Pont.Uplink)
    assert state.name_taken
    assert is_nil(state.websocket)
    assert Process.alive?(Process.whereis(Pont.Uplink))

    write_link!(url, %{"name" => "other"})
    send(Pont.Uplink, :watch)
    assert_receive {:socket, _}, 1_000
    assert_receive {:ws, hello}
    assert %{"params" => %{"name" => "other"}} = Jason.decode!(hello)
    refute :sys.get_state(Pont.Uplink).name_taken
  end

  test "a label change redials while the previous plane socket is still alive" do
    holder = start_plane(18_113)
    [{_, %Pont.Registry.Uplink{instance: instance}}] = :ets.lookup(:pont_runtimes, "opencode")
    assert is_binary(instance) and instance != ""
    assert :sys.suspend(holder) == :ok

    write_link!("ws://127.0.0.1:18113/agent", %{"label" => "renamed"})

    log =
      capture_info(fn ->
        send(Pont.Uplink, :watch)
        assert await_settled_pid("opencode", holder)
      end)

    assert log =~ "uplink reconnect name=opencode the same relay dialed again"
    refute log =~ "uplink rejected name=opencode"
    new_pid = Pont.Registry.pid("opencode")
    assert [%{"label" => "renamed"}] = Pont.Registry.list()

    [{_, %Pont.Registry.Uplink{instance: ^instance, pid: ^new_pid}}] =
      :ets.lookup(:pont_runtimes, "opencode")

    refute :sys.get_state(Pont.Uplink).name_taken
    release_holder(holder, new_pid)
  end

  test "a reconnect redials while the previous plane socket is still alive" do
    holder = start_plane(18_114)
    assert :sys.suspend(holder) == :ok

    log =
      capture_info(fn ->
        send(Pont.Uplink, :connect)
        assert await_settled_pid("opencode", holder)
      end)

    assert log =~ "uplink reconnect name=opencode the same relay dialed again"
    refute log =~ "uplink rejected name=opencode"
    new_pid = Pont.Registry.pid("opencode")
    refute :sys.get_state(Pont.Uplink).name_taken
    release_holder(holder, new_pid)
  end

  test "a normal close still redials" do
    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_112, ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:18112/agent")
    start_supervised!({Pont.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, _hello}
    send(socket, {:close, 1001, "going away"})
    assert_receive {:socket, _}, 1_000
    refute :sys.get_state(Pont.Uplink).name_taken
  end

  defp capture_info(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: level)
    end
  end

  defp start_plane(port) do
    previous = Application.get_env(:pont, :master_token)
    Application.put_env(:pont, :master_token, "sekret")
    on_exit(fn -> restore_token(previous) end)

    start_supervised!(Pont.Registry)
    start_supervised!(Pont.Plane)

    start_supervised!({Bandit, plug: Pont.Router, scheme: :http, port: port, ip: {127, 0, 0, 1}})

    write_link!("ws://127.0.0.1:#{port}/agent")
    start_supervised!({Pont.Uplink, owner: self()})
    await_pid("opencode")
  end

  defp await_pid(name, attempts \\ 100) do
    case Pont.Registry.pid(name) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(20)
        await_pid(name, attempts - 1)

      nil ->
        flunk("uplink #{name} did not register")
    end
  end

  defp await_settled_pid(name, holder, attempts \\ 40) do
    case Pont.Registry.pid(name) do
      pid when is_pid(pid) and pid != holder ->
        Process.sleep(50)

        case Pont.Registry.pid(name) do
          ^pid -> pid
          _ when attempts > 0 -> await_settled_pid(name, holder, attempts - 1)
          _ -> flunk("uplink #{name} dropped during reconnect")
        end

      _ when attempts > 0 ->
        Process.sleep(20)
        await_settled_pid(name, holder, attempts - 1)

      _ ->
        flunk("uplink #{name} stayed on the previous socket")
    end
  end

  defp release_holder(holder, new_pid) do
    ref = Process.monitor(holder)
    assert :sys.resume(holder) == :ok
    assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1_000
    Process.sleep(50)
    assert Pont.Registry.pid("opencode") == new_pid
    assert Process.alive?(new_pid)
    refute :sys.get_state(Pont.Uplink).name_taken
    true
  end

  defp await_name_taken(attempts \\ 50) do
    if :sys.get_state(Pont.Uplink).name_taken or attempts == 0 do
      assert :sys.get_state(Pont.Uplink).name_taken
    else
      Process.sleep(20)
      await_name_taken(attempts - 1)
    end
  end

  defp write_link!(url, attrs \\ %{}) do
    File.write!(
      Application.fetch_env!(:pont, :link_path),
      Jason.encode!(
        Map.merge(
          %{
            "name" => "opencode",
            "label" => "this machine",
            "program" => "opencode",
            "plane_url" => url
          },
          attrs
        )
      )
    )
  end

  defp restore_link(nil), do: Application.delete_env(:pont, :link_path)
  defp restore_link(path), do: Application.put_env(:pont, :link_path, path)
  defp restore_token(nil), do: Application.delete_env(:pont, :master_token)
  defp restore_token(value), do: Application.put_env(:pont, :master_token, value)
end
