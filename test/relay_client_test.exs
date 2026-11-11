defmodule AgentLink.Relay.ClientTest do
  use ExUnit.Case, async: false

  alias AgentLink.FakeStdio
  alias AgentLink.FakeTransport
  alias AgentLink.Relay.Client
  alias AgentLink.Relay.Target

  @plane "ws://127.0.0.1:9"
  @list_id "agentlink:runtime/list"
  @select_id "agentlink:runtime/select"

  test "the child spec does not restart a shutdown" do
    assert %{id: Client, restart: :transient} = Client.child_spec(plane: @plane)
  end

  test "plane is required, and token and target are a binary or nil" do
    assert_raise KeyError, fn ->
      Client.start_link(transport: FakeTransport, stdio: FakeStdio)
    end

    assert_raise ArgumentError, "plane must be a binary, got: :no", fn ->
      Client.start_link(plane: :no, transport: FakeTransport, stdio: FakeStdio)
    end

    assert_raise ArgumentError, "token must be a binary or nil, got: 1", fn ->
      Client.start_link(plane: @plane, token: 1, transport: FakeTransport, stdio: FakeStdio)
    end

    assert_raise ArgumentError, "target must be a binary or nil, got: :lab", fn ->
      Client.start_link(plane: @plane, target: :lab, transport: FakeTransport, stdio: FakeStdio)
    end
  end

  test "the dial uses /acp and the bearer token, then calls runtime/list" do
    client = start_client!(token: "secret", target: "lab")
    state = :sys.get_state(transport!(client))

    assert state.url == @plane
    assert state.default_path == "/acp"
    assert state.headers == [{"authorization", "Bearer secret"}]
    assert state.preface == nil

    assert sent(client) == [
             %{
               "jsonrpc" => "2.0",
               "id" => @list_id,
               "method" => "runtime/list",
               "params" => %{}
             }
           ]
  end

  test "an omitted, nil, or empty token does not send the plane master token" do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "plane-secret")

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:agent_link, :master_token)
      else
        Application.put_env(:agent_link, :master_token, previous)
      end
    end)

    omitted = start_client!()
    assert :sys.get_state(transport!(omitted)).headers == []

    for token <- [nil, ""] do
      client = start_client!(token: token)
      assert :sys.get_state(transport!(client)).headers == []
    end
  end

  test "nil target selects the only online agent, and a repeated name counts once" do
    client = start_client!()
    deliver(client, runtimes(["only", "only"]))

    assert sent(client) == [
             request(@list_id, "runtime/list", %{}),
             request(@select_id, "runtime/select", %{"name" => "only"})
           ]
  end

  test "target selects that agent when several are online" do
    client = start_client!(target: "lab")
    deliver(client, runtimes(["other", "lab"]))

    assert List.last(sent(client)) ==
             request(@select_id, "runtime/select", %{"name" => "lab"})
  end

  test "a bad target stops the client relay and the supervisor does not restart it" do
    assert_stops([], [], "No agent is online.\n")

    assert_stops(
      [],
      ["b", "a"],
      "Several agents are online: \"b\", \"a\". Pass --target.\n"
    )

    assert_stops(
      [target: "missing"],
      ["lab"],
      "\"missing\" is not online. Online agents: \"lab\". Pass --target.\n"
    )
  end

  test "a runtime error stops the client relay and the supervisor does not restart it" do
    assert_stops_with(
      [target: "lab"],
      fn client ->
        reply(@list_id, {:error, %{"code" => -32000, "message" => "runtime is not connected"}})
        |> then(&deliver_down(client, &1))
      end,
      "runtime is not connected"
    )

    assert_stops_with(
      [target: "lab"],
      fn client ->
        deliver(client, runtimes(["lab"]))

        deliver_down(
          client,
          reply(@select_id, {:error, %{"code" => -32000}})
        )
      end,
      "runtime request failed: %{\"code\" => -32000}"
    )
  end

  test "an unexpected runtime/list result stops the client relay" do
    assert_stops_with(
      [target: "lab"],
      fn client ->
        deliver_down(client, reply(@list_id, {:ok, %{"agents" => ["lab"]}}))
      end,
      "runtime/list returned an unexpected result"
    )

    assert_stops_with(
      [target: "lab"],
      fn client ->
        deliver_down(client, reply(@list_id, {:ok, %{"runtimes" => [%{"name" => 1}]}}))
      end,
      "runtime/list returned an unexpected result"
    )
  end

  test "editor messages wait until runtime/select, then copy in order" do
    client = start_client!(target: "lab")
    early = request(7, "session/list", %{"cwd" => "/tmp"})

    notice = %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s"}
    }

    push(client, Jason.encode!(early) <> "\n")
    refute Enum.any?(sent(client), &(&1["method"] == "session/list"))

    deliver(client, runtimes(["lab", "other"]))
    deliver(client, notice)
    assert written(client) == []

    deliver(client, reply(@select_id, {:ok, %{"name" => "lab"}}))

    assert sent(client) == [
             request(@list_id, "runtime/list", %{}),
             request(@select_id, "runtime/select", %{"name" => "lab"}),
             early
           ]

    assert decode_lines(client) == [notice]
  end

  test "a partial stdio line waits, and a later line is copied" do
    client = ready!(target: "lab")
    push(client, ~s({"method":"ping"))
    refute Enum.any?(sent(client), &(&1["method"] == "ping"))

    push(client, ~s(}\n{"method":"session/load","id":3,"params":{}}\n))

    assert Enum.take(sent(client), -2) == [
             %{"method" => "ping"},
             %{
               "method" => "session/load",
               "id" => 3,
               "params" => %{}
             }
           ]
  end

  test "session list, load, resume, and close are copied unchanged" do
    client = ready!()

    messages =
      for {method, id} <- [
            {"session/list", 1},
            {"session/load", 2},
            {"session/resume", 3},
            {"session/close", 4}
          ] do
        request(id, method, %{"sessionId" => "s", "cwd" => "/tmp"})
      end

    push(client, Enum.map_join(messages, "\n", &Jason.encode!/1) <> "\n")
    assert Enum.take(sent(client), -4) == messages

    answer = reply(2, {:ok, %{"sessions" => []}})
    deliver(client, answer)
    assert decode_lines(client) == [answer]
  end

  test "initialize result advertises load, list, resume, and close" do
    client = ready!()

    result = %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{
        "loadSession" => false,
        "promptCapabilities" => %{"image" => true},
        "sessionCapabilities" => %{
          "list" => %{"extra" => true},
          "delete" => %{},
          "resume" => nil
        }
      },
      "agentInfo" => %{"name" => "opencode"}
    }

    ask = request(4, "initialize", %{"clientCapabilities" => %{"fs" => %{}}})
    push(client, Jason.encode!(ask) <> "\n")
    assert List.last(sent(client)) == ask

    # A plane request that reuses the id is still copied, and the result is still rewritten.
    question = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "fs/read_text_file",
      "params" => %{"path" => "a"}
    }

    deliver(client, question)

    deliver(client, reply(4, {:ok, result}))

    expected = %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{
        "loadSession" => true,
        "promptCapabilities" => %{"image" => true},
        "sessionCapabilities" => %{
          "list" => %{"extra" => true},
          "delete" => %{},
          "resume" => %{},
          "close" => %{}
        }
      },
      "agentInfo" => %{"name" => "opencode"}
    }

    assert decode_lines(client) == [question, reply(4, {:ok, expected})]

    again = request(4, "session/new", %{})
    push(client, Jason.encode!(again) <> "\n")
    plain = reply(4, {:ok, %{"loadSession" => false}})
    deliver(client, plain)
    assert List.last(decode_lines(client)) == plain
  end

  test "initialize keeps a result that is not a map, and an error is copied" do
    client = ready!()
    push(client, Jason.encode!(request(8, "initialize", %{})) <> "\n")
    odd = reply(8, {:ok, "nope"})
    deliver(client, odd)
    assert decode_lines(client) == [odd]

    push(client, Jason.encode!(request(9, "initialize", %{})) <> "\n")

    error =
      reply(9, {:error, %{"code" => -32000, "message" => "runtime is down"}})

    deliver(client, error)
    assert List.last(decode_lines(client)) == error
  end

  test "a missing agentCapabilities map is replaced by the session advertisement" do
    client = ready!()
    push(client, Jason.encode!(request(1, "initialize", %{})) <> "\n")
    result = %{"protocolVersion" => 1, "agentCapabilities" => false, "authMethods" => []}
    deliver(client, reply(1, {:ok, result}))

    expected = %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{
        "loadSession" => true,
        "sessionCapabilities" => %{"list" => %{}, "resume" => %{}, "close" => %{}}
      },
      "authMethods" => []
    }

    assert decode_lines(client) == [reply(1, {:ok, expected})]
  end

  test "startup responses are not written to the editor" do
    client = ready!(target: "lab")

    deliver(
      client,
      reply(@list_id, {:ok, %{"runtimes" => [%{"name" => "lab"}]}})
    )

    deliver(client, reply(@select_id, {:ok, %{"name" => "lab", "label" => "Lab"}}))
    assert written(client) == []
  end

  test "a dropped stdio line is logged as a bounded prefix" do
    client = ready!()
    prefix = String.duplicate("x", 80)
    tail = "TAIL-NOT-LOGGED"
    before = length(sent(client))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        push(client, prefix <> tail <> "\n")
      end)

    assert log =~ "client relay dropped non-json stdio"
    assert log =~ prefix
    refute log =~ tail
    assert length(sent(client)) == before

    invalid = <<0x20, 0xFF>>

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        push(client, invalid <> "\n")
      end)

    assert log =~ "client relay dropped non-json stdio"
    assert log =~ inspect(invalid)
    assert Process.alive?(client)
  end

  test "a closed plane socket sends the in-flight runtime request again" do
    client = start_client!()
    transport = transport!(client)
    assert copies(transport, "runtime/list") == 1

    assert :ok = FakeTransport.disconnect(transport, 1006, "")
    :sys.get_state(client)
    assert copies(transport, "runtime/list") == 2
    assert :sys.get_state(client).phase == :list
    assert Process.alive?(client)

    other = start_client!(target: "lab")
    deliver(other, runtimes(["lab", "other"]))
    transport = transport!(other)
    assert copies(transport, "runtime/select") == 1

    assert :ok = FakeTransport.disconnect(transport, 1001, "bye")
    :sys.get_state(other)
    assert copies(transport, "runtime/select") == 2
    assert :sys.get_state(other).phase == :select
    assert Process.alive?(other)
  end

  test "stdio ending or a closed write stops the client relay" do
    {sup, client} = supervise(target: "lab")
    ready_client(client)
    stdio = :sys.get_state(client).stdio_term
    stdio_ref = Process.monitor(stdio)
    ref = Process.monitor(client)
    assert :ok = FakeStdio.eof(stdio)

    assert AgentLink.TestHelpers.await_down(ref, client) == {:shutdown, "stdio closed"}
    assert AgentLink.TestHelpers.await_down(stdio_ref, stdio) == :normal
    assert_not_restarted(sup)

    {_sup, client} = supervise()
    ready_client(client)
    ref = Process.monitor(client)
    FakeStdio.refuse(:sys.get_state(client).stdio_term)
    deliver_down(client, %{"jsonrpc" => "2.0", "method" => "session/update"})
    assert AgentLink.TestHelpers.await_down(ref, client) == {:shutdown, "stdio closed"}
  end

  test "a plane close after runtime/select holds the socket and stops" do
    {sup, client} = supervise()
    ready_client(client)
    transport = transport!(client)

    # The transport is linked to the client. Drop that link so the stop
    # does not take the transport down before the hold can be read.
    :sys.replace_state(client, fn state ->
      Process.unlink(state.transport_pid)
      state
    end)

    ref = Process.monitor(client)
    assert :ok = FakeTransport.disconnect(transport, 1006, "")
    assert AgentLink.TestHelpers.await_down(ref, client) == {:shutdown, "plane closed"}
    assert_not_restarted(sup)

    socket = :sys.get_state(transport)
    assert socket.held == true
    assert socket.timer == nil
    GenServer.stop(transport)
  end

  test "stopping the client relay closes stdio" do
    client = ready!()
    stdio = :sys.get_state(client).stdio_term
    ref = Process.monitor(stdio)
    GenServer.stop(client)
    assert AgentLink.TestHelpers.await_down(ref, stdio) == :normal
  end

  test "an unknown message is ignored" do
    client = ready!()
    send(client, :nope)
    assert :sys.get_state(client).phase == :copy
    assert Process.alive?(client)
  end

  test "stdio open failure stops with shutdown and does not restart" do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
    Process.unlink(sup)
    on_exit(fn -> stop_quietly(sup) end)

    spec = {Client, [plane: @plane, transport: FakeTransport, stdio: __MODULE__.BrokenStdio]}

    assert {:error, {{:shutdown, "stdio open failed: :busy"}, _child}} =
             Supervisor.start_child(sup, spec)

    assert Supervisor.which_children(sup) == []
  end

  defmodule BrokenStdio do
    @moduledoc false
    @behaviour AgentLink.Stdio

    def open(_owner), do: {:error, :busy}
    def write(_term, _data), do: :closed
    def close(_term), do: :ok
  end

  defp assert_stops(opts, names, message) do
    {:error, reason} = Target.select(Keyword.get(opts, :target), names)
    assert reason == message

    assert_stops_with(
      opts,
      fn client ->
        deliver_down(client, runtimes(names))
      end,
      message
    )
  end

  defp assert_stops_with(opts, fun, message) do
    {sup, client} = supervise(opts)
    ref = Process.monitor(client)
    fun.(client)
    assert AgentLink.TestHelpers.await_down(ref, client) == {:shutdown, message}
    assert_not_restarted(sup)
  end

  defp ready!(opts \\ []) do
    client = start_client!(opts)
    ready_client(client)
    client
  end

  defp ready_client(client) do
    deliver(client, runtimes(["lab"]))
    deliver(client, reply(@select_id, {:ok, %{"name" => "lab"}}))
    client
  end

  defp start_client!(opts \\ []) do
    {:ok, pid} = Client.start_link(options(opts))
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # A transient child that stops with {:shutdown, message} stays in the
  # supervisor with no pid. A restart would be a new pid.
  defp assert_not_restarted(sup) do
    assert [{Client, :undefined, :worker, [Client]}] = Supervisor.which_children(sup)
  end

  defp supervise(opts \\ []) do
    {:ok, sup} =
      Supervisor.start_link([{Client, options(opts)}], strategy: :one_for_one)

    Process.unlink(sup)
    on_exit(fn -> stop_quietly(sup) end)

    [{Client, client, :worker, [Client]}] = Supervisor.which_children(sup)
    {sup, client}
  end

  defp options(opts) do
    [plane: @plane, transport: FakeTransport, stdio: FakeStdio]
    |> Keyword.merge(opts)
  end

  defp transport!(client) do
    pid = :sys.get_state(client).transport_pid
    :sys.get_state(pid)
    pid
  end

  defp sent(client), do: FakeTransport.sent(transport!(client))

  defp copies(transport, method) do
    state = :sys.get_state(transport)
    Enum.count(state.sent ++ state.outbox, &(&1["method"] == method))
  end

  defp deliver(client, message) do
    assert :ok = FakeTransport.deliver(transport!(client), message)
    :sys.get_state(client)
    :ok
  end

  defp deliver_down(client, message) do
    assert :ok = FakeTransport.deliver(transport!(client), message)
    :ok
  end

  defp push(client, data) do
    :ok = FakeStdio.emit(:sys.get_state(client).stdio_term, data)
    :sys.get_state(client)
    :ok
  end

  defp written(client), do: FakeStdio.written(:sys.get_state(client).stdio_term)

  defp decode_lines(client) do
    Enum.map(written(client), &Jason.decode!/1)
  end

  defp runtimes(names) do
    rows = Enum.map(names, &%{"name" => &1, "label" => &1, "program" => "opencode"})
    reply(@list_id, {:ok, %{"runtimes" => rows}})
  end

  defp request(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp reply(id, {:ok, result}) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp reply(id, {:error, error}) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end
end
