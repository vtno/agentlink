defmodule AgentLink.UplinkTest do
  use ExUnit.Case, async: false

  alias AgentLink.FakeTransport

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
    url = "wss://plane.example:8443/agent"

    assert AgentLink.Uplink.endpoint(url) ==
             {:wss, :https, "plane.example", 8443, "/agent"}

    assert AgentLink.Uplink.endpoint(url) == AgentLink.Transport.endpoint(url, "/agent")
  end

  test "a missing link file stops the uplink" do
    Process.flag(:trap_exit, true)
    missing = "/tmp/agentlink-uplink-missing-#{System.unique_integer([:positive])}.json"
    Application.put_env(:agent_link, :link_path, missing)

    assert {:error, {:shutdown, message}} = AgentLink.Uplink.start_link(owner: self())
    assert message =~ "No link file"
    refute Process.whereis(AgentLink.Uplink)
  end

  test "a deleted link file stops the uplink on the next watch" do
    uplink = start_uplink()
    File.rm!(Application.get_env(:agent_link, :link_path))
    ref = Process.monitor(uplink)
    send(uplink, :watch)

    assert_receive {:DOWN, ^ref, :process, ^uplink, {:shutdown, message}}, 1_000
    assert message =~ "No link file"
    refute Process.whereis(AgentLink.Uplink)
  end

  test "the hello leads, and a plane object is forwarded" do
    uplink = start_uplink()
    assert [hello] = sent(uplink)

    assert hello == %{
             "jsonrpc" => "2.0",
             "method" => "agentlink.uplink",
             "params" => %{
               "name" => "opencode",
               "label" => "this machine",
               "program" => "opencode",
               "instance" => hello["params"]["instance"]
             }
           }

    assert hello["params"]["instance"] != ""

    :ok = AgentLink.Uplink.send_message(%{"method" => "out"})
    assert [^hello, %{"method" => "out"}] = sent(uplink)

    :ok = FakeTransport.deliver(transport_pid(uplink), %{"method" => "ping"})
    assert_receive {:from_plane, %{"method" => "ping"}}, 1_000

    send(uplink, :nope)
    sync(uplink)
    assert Process.alive?(uplink)
  end

  test "a message queued while down is sent after the hello" do
    uplink = start_uplink(accept: false)
    assert sent(uplink) == []

    :ok = AgentLink.Uplink.send_message(%{"method" => "ping"})
    :ok = AgentLink.Uplink.send_message(%{"method" => "pong"})
    :ok = FakeTransport.allow(transport_pid(uplink))

    write_link!("ws://127.0.0.1:1/agent", %{"label" => "renamed"})

    log =
      AgentLink.TestHelpers.capture_info(fn ->
        send(uplink, :watch)
        assert [hello, %{"method" => "ping"}, %{"method" => "pong"}] = sent(uplink)
        assert hello["method"] == "agentlink.uplink"
        assert hello["params"]["label"] == "renamed"
        assert hello["params"]["name"] == "opencode"
      end)

    assert log =~ "agent link changed, redialing as opencode"
  end

  test "an unchanged link file does not redial" do
    uplink = start_uplink()
    assert [hello] = sent(uplink)
    send(uplink, :watch)
    assert [^hello] = sent(uplink)
  end

  test "a new plane url redials with the same instance" do
    uplink = start_uplink()
    assert [hello] = sent(uplink)
    write_link!("ws://127.0.0.1:9/moved")

    log =
      AgentLink.TestHelpers.capture_info(fn ->
        send(uplink, :watch)
        assert [^hello, again] = sent(uplink)
        assert again["params"]["instance"] == hello["params"]["instance"]
        assert again["params"]["name"] == "opencode"
      end)

    assert log =~ "agent link changed, redialing as opencode"
    assert :sys.get_state(transport_pid(uplink)).url == "ws://127.0.0.1:9/moved"
    assert :sys.get_state(uplink).link.plane_url == "ws://127.0.0.1:9/moved"
  end

  test "a rejection of the socket reconnect just opened still parks" do
    uplink = start_uplink()
    assert [hello] = sent(uplink)
    transport = transport_pid(uplink)
    :ok = FakeTransport.close_next(transport, 4001, "")
    write_link!("ws://127.0.0.1:1/agent", %{"name" => "other"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(uplink, :watch)
        sync(uplink)
      end)

    assert :sys.get_state(uplink).rejection == :name_taken
    assert parked?(uplink)
    assert log =~ "uplink rejected name=other"
    assert [^hello, again] = sent(uplink)
    assert again["params"]["name"] == "other"
  end

  test "a close already in the transport is dropped when the link changes" do
    uplink = start_uplink()
    assert [hello] = sent(uplink)
    transport = transport_pid(uplink)
    :ok = FakeTransport.close_on_preface(transport, 4001, "")
    write_link!("ws://127.0.0.1:1/agent", %{"name" => "other"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(uplink, :watch)
        sync(uplink)
      end)

    state = :sys.get_state(uplink)
    assert state.rejection == nil
    assert state.link.name == "other"
    refute parked?(uplink)
    refute log =~ "uplink rejected"

    assert [^hello, again] = sent(uplink)
    assert again["params"]["name"] == "other"
  end

  test "a link change still redials when a rejection is already queued" do
    uplink = start_uplink()
    assert [_] = sent(uplink)
    transport = transport_pid(uplink)

    :ok = :sys.suspend(uplink)

    on_exit(fn ->
      if Process.alive?(uplink) do
        try do
          :sys.resume(uplink)
        catch
          _, _ -> :ok
        end
      end
    end)

    write_link!("ws://127.0.0.1:1/agent", %{"name" => "other"})
    send(uplink, :watch)
    :ok = FakeTransport.disconnect(transport, 4001, "")
    :ok = :sys.resume(uplink)
    sync(uplink)

    state = :sys.get_state(uplink)
    assert state.rejection == nil
    assert state.link.name == "other"
    assert :sys.get_state(transport).held == false

    assert [_, again] = sent(uplink)
    assert again["params"]["name"] == "other"
  end

  test "an instance-too-long close does not redial until restart" do
    uplink = start_uplink()
    assert [hello] = sent(uplink)
    code = AgentLink.AgentSocketProtocol.close_code(:instance_too_long)
    reason = AgentLink.AgentSocketProtocol.reason(:instance_too_long)
    log = park(uplink, code, "")

    assert log =~ "uplink rejected name=opencode"
    assert log =~ reason
    assert log =~ "Fix the relay instance id and restart this relay"
    assert log =~ "This relay will not reconnect until restart"

    write_link!("ws://127.0.0.1:1/agent", %{"label" => "other label"})
    send(uplink, :watch)
    write_link!("ws://127.0.0.1:1/agent", %{"name" => "other"})
    send(uplink, :watch)
    write_link!("ws://127.0.0.1:9/agent", %{"name" => "other"})
    send(uplink, :watch)
    sync(uplink)

    state = :sys.get_state(uplink)
    assert state.rejection == :instance_too_long
    assert [^hello] = sent(uplink)
    assert parked?(uplink)
    assert Process.alive?(uplink)

    stop_supervised!(AgentLink.Uplink)
    restarted = start_uplink()
    assert [_] = sent(restarted)
    assert :sys.get_state(restarted).rejection == nil
  end

  for {rejection, code, hint} <- [
        {:name_taken, 4001, "Stop the other relay and restart this one, or change name in"},
        {:bad_name, 4003, "Fix name in"},
        {:not_allowed, 4004, "Ask the plane operator to allow this uplink"}
      ],
      {reason_kind, reason_label} <- [empty: "an empty", provided: "a provided"] do
    @tag rejection: rejection, code: code, hint: hint, reason_kind: reason_kind
    test "#{rejection} parks with #{reason_label} reason until the link target changes", %{
      rejection: rejection,
      code: code,
      hint: hint,
      reason_kind: reason_kind
    } do
      uplink = start_uplink()
      url = "ws://127.0.0.1:1/agent"
      assert [_] = sent(uplink)

      reason = if reason_kind == :empty, do: "", else: "plane rejection details"
      log = park(uplink, code, reason)

      detail =
        if reason == "",
          do: AgentLink.AgentSocketProtocol.reason(rejection, "opencode"),
          else: reason

      assert log =~ "uplink rejected name=opencode #{detail}"
      assert log =~ hint
      assert log =~ "will not reconnect until name or plane_url changes, or restart"
      assert parked?(uplink)

      send(uplink, :connect)
      write_link!(url, %{"label" => "other", "program" => "other"})
      send(uplink, :watch)
      sync(uplink)
      assert :sys.get_state(uplink).rejection == rejection
      assert [_] = sent(uplink)
      assert parked?(uplink)

      if reason_kind == :empty do
        write_link!(url, %{"name" => "other"})
      else
        write_link!("ws://127.0.0.1:9/other")
      end

      send(uplink, :watch)
      messages = sent(uplink)
      assert :sys.get_state(uplink).rejection == nil
      assert length(messages) == 2
      assert List.last(messages)["method"] == "agentlink.uplink"
      refute parked?(uplink)
    end
  end

  test "a transient close does not park" do
    for code <- [1001, 4010] do
      uplink = start_uplink()
      assert [_] = sent(uplink)
      :ok = FakeTransport.disconnect(transport_pid(uplink), code, "going away")
      sync(uplink)
      assert :sys.get_state(uplink).rejection == nil
      socket = :sys.get_state(transport_pid(uplink))
      assert socket.held == false
      assert socket.timer != nil
      stop_supervised!(AgentLink.Uplink)
    end
  end

  test "the hello registers this relay with the plane" do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")
    on_exit(fn -> AgentLink.TestHelpers.restore(:master_token, previous) end)

    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane)

    server =
      start_supervised!(
        {Bandit, plug: AgentLink.Router, scheme: :http, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    write_link!("ws://127.0.0.1:#{port}/agent")

    start_supervised!(%{
      id: AgentLink.Uplink,
      start: {AgentLink.Uplink, :start_link, [[owner: self()]]},
      restart: :temporary
    })

    pid = AgentLink.TestHelpers.await_pid("opencode")
    assert is_pid(pid)

    assert [%{"name" => "opencode", "label" => "this machine", "program" => "opencode"}] =
             Enum.map(AgentLink.Registry.list(), &Map.take(&1, ["name", "label", "program"]))

    [{_, %AgentLink.Registry.Uplink{instance: instance, pid: ^pid}}] =
      :ets.lookup(:agent_link_runtimes, "opencode")

    assert is_binary(instance) and instance != ""
  end

  defp start_uplink(opts \\ []) do
    transport_opts = Keyword.put_new(opts, :backoff, 60_000)

    start_supervised!(%{
      id: AgentLink.Uplink,
      start:
        {AgentLink.Uplink, :start_link,
         [[owner: self(), transport: FakeTransport, transport_opts: transport_opts]]},
      restart: :temporary
    })
  end

  # A watch may queue a close from `preface/2`, then `{:replaced, ref}`, then
  # dial. The second read runs whatever that watch left in the mailbox.
  defp sync(uplink) do
    :sys.get_state(uplink)
    :sys.get_state(uplink)
  end

  defp sent(uplink) do
    sync(uplink)
    FakeTransport.sent(transport_pid(uplink))
  end

  defp transport_pid(uplink), do: :sys.get_state(uplink).transport_pid

  defp park(uplink, code, reason) do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = FakeTransport.disconnect(transport_pid(uplink), code, reason)
        sync(uplink)
      end)

    assert :sys.get_state(uplink).rejection == AgentLink.AgentSocketProtocol.rejection(code)
    assert parked?(uplink)
    log
  end

  defp parked?(uplink) do
    socket = :sys.get_state(transport_pid(uplink))
    socket.held == true and socket.timer == nil
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
end
