defmodule AgentLink.UplinkTest do
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
    link_path = Application.get_env(:agent_link, :link_path)

    path =
      Path.join(System.tmp_dir!(), "agentlink-uplink-#{System.unique_integer([:positive])}.json")

    Application.put_env(:agent_link, :link_path, path)
    write_link!("ws://127.0.0.1:1/agent")

    on_exit(fn ->
      restore_link(link_path)
      File.rm(path)
      if pid = Process.whereis(AgentLink.Uplink), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  test "a plane URL keeps ws plain and dials wss as TLS" do
    assert AgentLink.Uplink.endpoint("ws://127.0.0.1:8090/agent") ==
             {:ws, :http, "127.0.0.1", 8090, "/agent"}

    assert AgentLink.Uplink.endpoint("ws://127.0.0.1/agent") ==
             {:ws, :http, "127.0.0.1", 80, "/agent"}

    assert AgentLink.Uplink.endpoint("http://127.0.0.1:8090/agent") ==
             {:ws, :http, "127.0.0.1", 8090, "/agent"}

    assert AgentLink.Uplink.endpoint("wss://plane.example/agent") ==
             {:wss, :https, "plane.example", 443, "/agent"}

    assert AgentLink.Uplink.endpoint("wss://plane.example:8443/agent") ==
             {:wss, :https, "plane.example", 8443, "/agent"}

    assert AgentLink.Uplink.endpoint("wss://plane.example") ==
             {:wss, :https, "plane.example", 443, "/agent"}

    assert AgentLink.Uplink.endpoint("https://plane.example/agent") ==
             {:wss, :https, "plane.example", 443, "/agent"}
  end

  test "a missing link file stops the uplink" do
    Process.flag(:trap_exit, true)
    missing = "/tmp/agentlink-uplink-missing-#{System.unique_integer([:positive])}.json"
    Application.put_env(:agent_link, :link_path, missing)

    assert {:error, {:shutdown, message}} = AgentLink.Uplink.start_link(owner: self())
    assert message =~ "No link file"
    refute Process.whereis(AgentLink.Uplink)
  end

  test "a deleted link file stops the uplink on the next dial" do
    pid =
      start_supervised!(%{
        id: AgentLink.Uplink,
        start: {AgentLink.Uplink, :start_link, [[owner: self()]]},
        restart: :temporary
      })

    :sys.get_state(pid)
    File.rm!(Application.get_env(:agent_link, :link_path))
    ref = Process.monitor(pid)
    send(pid, :connect)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, message}}
    assert message =~ "No link file"
    refute Process.whereis(AgentLink.Uplink)
  end

  test "a deleted link file stops the uplink on the next watch" do
    pid =
      start_supervised!(%{
        id: AgentLink.Uplink,
        start: {AgentLink.Uplink, :start_link, [[owner: self()]]},
        restart: :temporary
      })

    :sys.get_state(pid)
    File.rm!(Application.get_env(:agent_link, :link_path))
    ref = Process.monitor(pid)
    send(pid, :watch)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, message}}
    assert message =~ "No link file"
    refute Process.whereis(AgentLink.Uplink)
  end

  test "the uplink sends the bearer token when it dials" do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")
    on_exit(fn -> restore_token(previous) end)

    start_supervised!(
      {Bandit,
       plug: {AgentLink.UplinkTest.AuthPlug, self()},
       scheme: :http,
       port: 18_093,
       ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:18093/agent")
    start_supervised!({AgentLink.Uplink, owner: self()})
    assert_receive {:auth, ["Bearer sekret"]}
  end

  test "a message waits in the outbox while the plane is down" do
    start_supervised!({AgentLink.Uplink, owner: self()})
    AgentLink.Uplink.send_message(%{"method" => "ping"})
    Process.sleep(50)
    assert %{"method" => "ping"} in :sys.get_state(AgentLink.Uplink).outbox
    send(AgentLink.Uplink, :nope)
    send(AgentLink.Uplink, :watch)
    assert Process.alive?(Process.whereis(AgentLink.Uplink))
  end

  test "a handshake that is not a websocket is retried" do
    start_supervised!({Bandit, plug: HttpPlain, scheme: :http, port: 18_094, ip: {127, 0, 0, 1}})
    write_link!("ws://127.0.0.1:18094/agent")
    start_supervised!({AgentLink.Uplink, owner: self()})
    Process.sleep(200)
    assert Process.alive?(Process.whereis(AgentLink.Uplink))
    assert :sys.get_state(AgentLink.Uplink).websocket == nil
  end

  test "a connected uplink sends, receives, and redials when the link changes" do
    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_095, ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:18095/agent")
    start_supervised!({AgentLink.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, hello}
    assert %{"method" => "agentlink.uplink"} = Jason.decode!(hello)

    send(socket, {:push, {:text, ~s({"jsonrpc":"2.0","method":"ping"})}})
    assert_receive {:from_plane, %{"method" => "ping"}}

    send(socket, {:push, {:binary, ~s({"jsonrpc":"2.0","method":"bin"})}})
    assert_receive {:from_plane, %{"method" => "bin"}}

    send(socket, {:push, {:text, "not-json"}})
    refute_receive {:from_plane, _}, 50

    send(socket, {:push, {:ping, "z"}})
    AgentLink.Uplink.send_message(%{"method" => "out"})
    assert_receive {:ws, out}
    assert %{"method" => "out"} = Jason.decode!(out)

    write_link!("ws://127.0.0.1:1/agent")
    send(AgentLink.Uplink, :watch)
    Process.sleep(200)
    assert :sys.get_state(AgentLink.Uplink).websocket == nil
  end

  test "a name-taken close does not redial until the link name changes" do
    url = "ws://127.0.0.1:18111/agent"

    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_111, ip: {127, 0, 0, 1}}
    )

    write_link!(url)
    start_supervised!({AgentLink.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, hello}
    assert %{"method" => "agentlink.uplink"} = Jason.decode!(hello)

    reason = AgentLink.AgentSocketProtocol.reason(:name_taken, "opencode")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(socket, {:close, 4001, ""})
        assert await_rejection(:name_taken)
      end)

    assert log =~ "uplink rejected name=opencode"
    assert log =~ reason
    assert log =~ "Another relay is already connected with this name"

    assert log =~
             "Stop the other relay and restart this one, or change name in #{AgentLink.Paths.link()}"

    assert log =~ "will not reconnect until name or plane_url changes"

    send(AgentLink.Uplink, :connect)
    write_link!(url, %{"label" => "other label"})
    send(AgentLink.Uplink, :watch)
    refute_receive {:socket, _}, 1_000

    state = :sys.get_state(AgentLink.Uplink)
    assert state.rejection == :name_taken
    assert is_nil(state.websocket)
    assert Process.alive?(Process.whereis(AgentLink.Uplink))

    write_link!(url, %{"name" => "other"})
    send(AgentLink.Uplink, :watch)
    assert_receive {:socket, _}, 1_000
    assert_receive {:ws, hello}
    assert %{"params" => %{"name" => "other"}} = Jason.decode!(hello)
    assert :sys.get_state(AgentLink.Uplink).rejection == nil
  end

  test "an instance-too-long close does not redial" do
    url = "ws://127.0.0.1:18115/agent"

    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_115, ip: {127, 0, 0, 1}}
    )

    write_link!(url)
    start_supervised!({AgentLink.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, hello}
    assert %{"method" => "agentlink.uplink"} = Jason.decode!(hello)

    reason = AgentLink.AgentSocketProtocol.reason(:instance_too_long)
    code = AgentLink.AgentSocketProtocol.close_code(:instance_too_long)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(socket, {:close, code, ""})
        assert await_rejection(:instance_too_long)
      end)

    assert log =~ "uplink rejected name=opencode"
    assert log =~ reason
    assert log =~ "This relay will not reconnect"

    send(AgentLink.Uplink, :connect)
    write_link!(url, %{"label" => "other label"})
    send(AgentLink.Uplink, :watch)
    write_link!(url, %{"name" => "other"})
    send(AgentLink.Uplink, :watch)
    write_link!(url <> "-other", %{"name" => "other"})
    send(AgentLink.Uplink, :watch)
    refute_receive {:socket, _}, 1_000

    state = :sys.get_state(AgentLink.Uplink)
    assert state.rejection == :instance_too_long
    assert is_nil(state.websocket)
    assert Process.alive?(Process.whereis(AgentLink.Uplink))

    stop_supervised!(AgentLink.Uplink)
    start_supervised!({AgentLink.Uplink, owner: self()})
    assert_receive {:socket, _}, 1_000
    assert_receive {:ws, _hello}
    assert :sys.get_state(AgentLink.Uplink).rejection == nil
  end

  test "a label change redials while the previous plane socket is still alive" do
    holder = start_plane(18_113)

    [{_, %AgentLink.Registry.Uplink{instance: instance}}] =
      :ets.lookup(:agent_link_runtimes, "opencode")

    assert is_binary(instance) and instance != ""
    assert :sys.suspend(holder) == :ok

    write_link!("ws://127.0.0.1:18113/agent", %{"label" => "renamed"})

    log =
      AgentLink.TestHelpers.capture_info(fn ->
        send(AgentLink.Uplink, :watch)
        assert await_settled_pid("opencode", holder)
      end)

    assert log =~ "uplink reconnect name=opencode the same relay dialed again"
    refute log =~ "uplink rejected name=opencode"
    new_pid = AgentLink.Registry.pid("opencode")
    assert [%{"label" => "renamed"}] = AgentLink.Registry.list()

    [{_, %AgentLink.Registry.Uplink{instance: ^instance, pid: ^new_pid}}] =
      :ets.lookup(:agent_link_runtimes, "opencode")

    assert :sys.get_state(AgentLink.Uplink).rejection == nil
    release_holder(holder, new_pid)
  end

  for {rejection, code, hint} <- [
        {:name_taken, 4001, "Stop the other relay and restart this one"},
        {:bad_name, 4003, "Fix name in"},
        {:not_allowed, 4004, "Ask the plane operator to allow this uplink"}
      ],
      reason_kind <- [:empty, :provided] do
    @tag rejection: rejection, code: code, hint: hint, reason_kind: reason_kind
    test "#{rejection} parks with a #{reason_kind} reason until the link target changes", %{
      rejection: rejection,
      code: code,
      hint: hint,
      reason_kind: reason_kind
    } do
      server =
        start_supervised!(
          {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 0, ip: {127, 0, 0, 1}}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      url = "ws://127.0.0.1:#{port}/agent"
      write_link!(url)
      start_supervised!({AgentLink.Uplink, owner: self()})
      assert_receive {:socket, socket}
      assert_receive {:ws, _hello}

      reason = if reason_kind == :empty, do: "", else: "plane rejection details"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(socket, {:close, code, reason})
          assert await_rejection(rejection)
        end)

      detail =
        if reason == "",
          do: AgentLink.AgentSocketProtocol.reason(rejection, "opencode"),
          else: reason

      assert log =~ "uplink rejected name=opencode #{detail}"
      assert log =~ hint
      assert log =~ "will not reconnect until name or plane_url changes, or restart"

      # Even an already queued retry and label/program edits must not unpark it.
      send(AgentLink.Uplink, :connect)
      write_link!(url, %{"label" => "other", "program" => "other"})
      send(AgentLink.Uplink, :watch)
      refute_receive {:socket, _}, 650
      assert :sys.get_state(AgentLink.Uplink).rejection == rejection
      assert :sys.get_state(AgentLink.Uplink).websocket == nil

      if reason_kind == :empty do
        write_link!(url, %{"name" => "other"})
      else
        write_link!(url <> "-other")
      end

      send(AgentLink.Uplink, :watch)
      assert_receive {:socket, _}, 1_000
      assert_receive {:ws, _hello}
      assert :sys.get_state(AgentLink.Uplink).rejection == nil
    end
  end

  test "a reconnect redials while the previous plane socket is still alive" do
    holder = start_plane(18_114)
    assert :sys.suspend(holder) == :ok

    log =
      AgentLink.TestHelpers.capture_info(fn ->
        send(AgentLink.Uplink, :connect)
        assert await_settled_pid("opencode", holder)
      end)

    assert log =~ "uplink reconnect name=opencode the same relay dialed again"
    refute log =~ "uplink rejected name=opencode"
    new_pid = AgentLink.Registry.pid("opencode")
    assert :sys.get_state(AgentLink.Uplink).rejection == nil
    release_holder(holder, new_pid)
  end

  test "a normal close still redials" do
    start_supervised!(
      {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 18_112, ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:18112/agent")
    start_supervised!({AgentLink.Uplink, owner: self()})

    assert_receive {:socket, socket}
    assert_receive {:ws, _hello}
    send(socket, {:close, 1001, "going away"})
    assert_receive {:socket, _}, 1_000
    assert :sys.get_state(AgentLink.Uplink).rejection == nil
  end

  test "an unknown close code still retries after 500ms" do
    server =
      start_supervised!(
        {Bandit, plug: {WsPlug, self()}, scheme: :http, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    write_link!("ws://127.0.0.1:#{port}/agent")
    start_supervised!({AgentLink.Uplink, owner: self()})
    assert_receive {:socket, socket}
    assert_receive {:ws, _hello}
    send(socket, {:close, 4010, "temporary failure"})
    refute_receive {:socket, _}, 400
    assert_receive {:socket, _}, 1_000
    assert_receive {:ws, _hello}
    assert :sys.get_state(AgentLink.Uplink).rejection == nil
  end

  defp start_plane(port) do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")
    on_exit(fn -> restore_token(previous) end)

    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane)

    start_supervised!(
      {Bandit, plug: AgentLink.Router, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    write_link!("ws://127.0.0.1:#{port}/agent")
    start_supervised!({AgentLink.Uplink, owner: self()})
    AgentLink.TestHelpers.await_pid("opencode")
  end

  defp await_settled_pid(name, holder, attempts \\ 40) do
    case AgentLink.Registry.pid(name) do
      pid when is_pid(pid) and pid != holder ->
        Process.sleep(50)

        case AgentLink.Registry.pid(name) do
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
    assert AgentLink.Registry.pid("opencode") == new_pid
    assert Process.alive?(new_pid)
    assert :sys.get_state(AgentLink.Uplink).rejection == nil
    true
  end

  defp await_rejection(rejection, attempts \\ 50) do
    if :sys.get_state(AgentLink.Uplink).rejection == rejection or attempts == 0 do
      assert :sys.get_state(AgentLink.Uplink).rejection == rejection
    else
      Process.sleep(20)
      await_rejection(rejection, attempts - 1)
    end
  end

  defp write_link!(url, attrs \\ %{}) do
    path = Application.fetch_env!(:agent_link, :link_path)

    body =
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

    tmp = path <> ".tmp"
    File.write!(tmp, body)
    File.rename!(tmp, path)
  end

  defp restore_link(nil), do: Application.delete_env(:agent_link, :link_path)
  defp restore_link(path), do: Application.put_env(:agent_link, :link_path, path)
  defp restore_token(nil), do: Application.delete_env(:agent_link, :master_token)
  defp restore_token(value), do: Application.put_env(:agent_link, :master_token, value)
end
