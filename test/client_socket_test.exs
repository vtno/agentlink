defmodule AgentLink.ClientSocketTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane.Sessions)
    start_supervised!(AgentLink.Plane)
    :ok
  end

  test "a client socket registers, forwards text, and pushes a reply" do
    {:ok, state} = AgentLink.ClientSocket.init(%AgentLink.Access.Subject{})
    assert is_binary(state.id)

    {:ok, state} =
      AgentLink.ClientSocket.handle_in(
        {~s({"jsonrpc":"2.0","method":"runtime/list"}), [opcode: :text]},
        state
      )

    {:ok, state} = AgentLink.ClientSocket.handle_in({<<1, 2>>, [opcode: :binary]}, state)

    assert {:push, [{:text, "{}"}], ^state} =
             AgentLink.ClientSocket.handle_info({:send, "{}"}, state)

    assert {:ok, ^state} = AgentLink.ClientSocket.handle_info(:other, state)
    assert :ok = AgentLink.ClientSocket.terminate(:normal, state)
  end

  test "a keepalive tick pushes a ping and a pong clears the deadline" do
    start_supervised!(AgentLink.FakeScheduler)
    {:ok, state} = AgentLink.ClientSocket.init({admin(), keepalive_opts()})

    assert AgentLink.FakeScheduler.scheduled(state.keepalive.ping_timer) ==
             {self(), {:keepalive_ping, state.keepalive.ping_token}, 30_000}

    assert {:push, [{:ping, ""}], armed} =
             AgentLink.ClientSocket.handle_info(
               {:keepalive_ping, state.keepalive.ping_token},
               state
             )

    token = armed.keepalive.pong_token
    assert {:ok, cleared} = AgentLink.ClientSocket.handle_control({"", [opcode: :pong]}, armed)
    assert cleared.keepalive.pong_token == nil

    assert {:ok, ^cleared} =
             AgentLink.ClientSocket.handle_info({:keepalive_expired, token}, cleared)

    {:ok, from_config} =
      AgentLink.ClientSocket.init({admin(), scheduler: AgentLink.FakeScheduler})

    assert from_config.keepalive.interval == 3_600_000
    assert from_config.keepalive.timeout == 3_600_000
  end

  test "a missed pong drops the client's sessions and queued prompts" do
    start_supervised!(AgentLink.FakeScheduler)
    agent = spawn_agent("lab")
    {pid, state} = AgentLink.SocketLoop.start(AgentLink.ClientSocket, {admin(), keepalive_opts()})
    id = state.id
    ref = Process.monitor(pid)

    AgentLink.Plane.client_frame(id, call(1, "runtime/select", %{"name" => "lab"}))
    assert %{"id" => 1, "result" => %{"name" => "lab"}} = pushed_json(pid)

    AgentLink.Plane.client_frame(
      id,
      call("new", "session/new", %{"cwd" => "/tmp", "mcpServers" => []})
    )

    assert_receive {:agent, %{"id" => agent_id, "method" => "session/new"}}

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"sessionId" => "ses_1"}
      })
    )

    assert %{"result" => %{"sessionId" => "ses_1"}} = pushed_json(pid)

    AgentLink.Plane.client_frame(id, prompt(8))
    assert %{"method" => "session/update"} = pushed_json(pid)
    assert_receive {:agent, %{"method" => "session/prompt"}}

    AgentLink.Plane.client_frame(id, prompt(9))
    _ = :sys.get_state(AgentLink.Plane)
    assert :queue.len(:sys.get_state(AgentLink.Plane).slots["lab"].prompt_queue["ses_1"]) == 1
    assert Map.has_key?(:sys.get_state(AgentLink.Plane.Sessions).clients, id)

    socket = AgentLink.SocketLoop.state(pid)
    :ok = AgentLink.FakeScheduler.fire(socket.keepalive.ping_timer)
    assert_receive {:socket_loop, ^pid, :push, [{:ping, ""}]}
    socket = AgentLink.SocketLoop.state(pid)
    :ok = AgentLink.FakeScheduler.fire(socket.keepalive.pong_timer)
    assert AgentLink.TestHelpers.await_down(ref, pid) == :normal

    AgentLink.TestHelpers.await(fn ->
      not Map.has_key?(:sys.get_state(AgentLink.Plane).clients, id)
    end)

    slot = :sys.get_state(AgentLink.Plane).slots["lab"]
    assert slot.prompt_queue == %{}

    assert Enum.any?(slot.agent_pending, fn {_agent_id, pending} ->
             pending.client_id == id and pending.client_req_id == 8
           end)

    refute Map.has_key?(:sys.get_state(AgentLink.Plane.Sessions).clients, id)
    refute Process.alive?(pid)
    AgentLink.TestHelpers.kill_and_wait(agent)
  end

  defp admin, do: %AgentLink.Access.Subject{id: "admin", role: :admin}

  defp keepalive_opts do
    [scheduler: AgentLink.FakeScheduler, ping_interval: 30_000, pong_timeout: 10_000]
  end

  defp call(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp prompt(id) do
    call(id, "session/prompt", %{
      "sessionId" => "ses_1",
      "prompt" => [%{"type" => "text", "text" => "go"}]
    })
  end

  defp pushed_json(pid) do
    assert_receive {:socket_loop, ^pid, :push, [{:text, json}]}
    Jason.decode!(json)
  end

  defp spawn_agent(name) do
    parent = self()
    pid = spawn(fn -> agent_loop(parent) end)

    {:ok, ^name} =
      AgentLink.Registry.register(
        pid,
        %AgentLink.Registry.Uplink{name: name, label: name},
        admin()
      )

    pid
  end

  defp agent_loop(parent) do
    receive do
      {:send, json} ->
        send(parent, {:agent, Jason.decode!(json)})
        agent_loop(parent)
    end
  end
end
