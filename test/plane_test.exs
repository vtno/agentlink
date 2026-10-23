defmodule Pont.PlaneTest do
  use ExUnit.Case, async: false

  defmodule Gate do
    @behaviour Pont.Access

    def authenticate(_conn), do: {:ok, %Pont.Access.Subject{id: "ada", role: :user}}
    def allowed?(_subject, "hidden"), do: false
    def allowed?(%Pont.Access.Subject{}, runtime) when is_binary(runtime), do: true
    def claim(_subject, _name), do: :ok
    def prepare(_mode), do: {:ok, ""}
  end

  setup do
    start_supervised!(Pont.Registry)
    start_supervised!(Pont.Plane)
    :ok
  end

  test "a batch is rejected and garbage is a parse error" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    Pont.Plane.client_frame(id, "[1]\nnot-json")
    assert %{"error" => %{"code" => -32600}} = reply!()
    assert %{"error" => %{"code" => -32700}} = reply!()
  end

  test "a message with no method is ignored" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    Pont.Plane.client_frame(id, ~s({"jsonrpc":"2.0","id":1}))
    refute_receive {:send, _}, 50
  end

  test "runtime list and select" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    call(id, "runtime/list", %{}, 1)
    assert %{"result" => %{"runtimes" => []}} = reply!()

    call(id, "runtime/select", %{}, 2)
    assert %{"error" => %{"message" => "runtime name is required"}} = reply!()

    call(id, "runtime/select", %{"name" => "missing"}, 3)
    assert %{"error" => %{"message" => "runtime is not connected"}} = reply!()

    agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 4)
    assert %{"id" => 4, "result" => %{"name" => "lab"}} = reply!()
  end

  test "a runtime notice is ignored" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    Pont.Plane.client_frame(id, ~s({"jsonrpc":"2.0","method":"runtime/list"}))
    refute_receive {:send, _}, 50
  end

  test "no runtime, one runtime is chosen, two runtimes must be chosen" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    assert %{"error" => %{"message" => "no runtime connected"}} = reply!()

    agent!("only")
    call(id, "initialize", %{}, 2)
    assert {:agent, %{"method" => "initialize"}} = from_agent!()

    other = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("other")
    call(other, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 3)
    assert %{"error" => %{"message" => "select a runtime"}} = reply!()
  end

  test "initialize is cached and a second caller waits for the same reply" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()

    {other, other_id} = spawn_client()
    call(id, "initialize", %{}, 2)
    assert {:agent, %{"id" => agent_id}} = from_agent!()
    call(other_id, "initialize", %{}, 3)
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"ok" => true}}))
    assert %{"id" => 2, "result" => %{"ok" => true}} = reply!()
    assert %{"id" => 3, "result" => %{"ok" => true}} = client_reply!(other)

    call(id, "initialize", %{}, 4)
    assert %{"id" => 4, "result" => %{"ok" => true}} = reply!()
    refute_receive {:agent, _}, 50
  end

  test "a failed initialize is not cached" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "initialize", %{}, 1)
    assert {:agent, %{"id" => agent_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "error" => %{"code" => 1, "message" => "no"}}))
    assert %{"id" => 1, "error" => %{"message" => "no"}} = reply!()

    call(id, "initialize", %{}, 2)
    assert {:agent, %{"method" => "initialize"}} = from_agent!()
  end

  test "session new and load bind the session, and an error does not" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    assert {:agent, %{"id" => agent_id, "method" => "session/new"}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "error" => %{"code" => 1, "message" => "no"}}))
    assert %{"error" => _} = reply!()

    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 2)
    assert {:agent, %{"id" => agent_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"sessionId" => "ses_1"}}))
    assert %{"result" => %{"sessionId" => "ses_1"}} = reply!()

    call(id, "session/load", %{"sessionId" => "ses_2", "cwd" => "/tmp", "mcpServers" => []}, 3)
    assert {:agent, %{"id" => agent_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{}}))
    assert %{"id" => 3, "result" => %{}} = reply!()
  end

  test "prompts run one at a time and the stop is broadcast" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")

    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "hi"}]}, 10)
    assert %{"method" => "session/update"} = reply!()
    assert {:agent, %{"id" => first, "method" => "session/prompt"}} = from_agent!()

    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "next"}]}, 11)
    refute_receive {:agent, _}, 50

    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => first, "result" => %{"stopReason" => "end_turn"}}))
    assert %{"id" => 10, "result" => %{"stopReason" => "end_turn"}} = reply!()
    assert %{"params" => %{"update" => %{"_meta" => %{"stopReason" => "end_turn"}}}} = reply!()
    assert {:agent, %{"id" => second, "method" => "session/prompt"}} = from_agent!()
    assert %{"method" => "session/update"} = reply!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => second, "error" => %{"code" => 1, "message" => "boom"}}))
    assert %{"id" => 11, "error" => _} = reply!()
    assert %{"params" => %{"update" => %{"_meta" => %{"stopReason" => "error"}}}} = reply!()
  end

  test "a prompt with no text and no session still runs, and a cancel is not queued" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "session/prompt", %{"prompt" => []}, 1)
    assert {:agent, %{"method" => "session/prompt", "id" => agent_id}} = from_agent!()
    refute_receive {:send, _}, 50

    Pont.Plane.client_frame(id, ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"x"}}))
    assert {:agent, %{"method" => "session/cancel"}} = from_agent!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{}}))
    assert %{"id" => 1} = reply!()
    refute_receive {:send, _}, 50
  end

  test "a live update goes only to clients on that session, unless a load is in flight" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    {other, other_id} = spawn_client()
    call(other_id, "runtime/select", %{"name" => "lab"}, 1)
    assert %{"id" => 1} = client_reply!(other)

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "ses_1", "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "yo"}}}
    }))
    assert %{"method" => "session/update"} = reply!()
    refute_receive {^other, {:send, _}}, 50

    call(other_id, "session/load", %{"sessionId" => "ses_9", "cwd" => "/tmp", "mcpServers" => []}, 2)
    assert {:agent, %{"method" => "session/load", "id" => load_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "ses_9", "update" => %{"sessionUpdate" => "agent_message_chunk"}}
    }))
    assert %{"method" => "session/update"} = client_reply!(other)
    refute_receive {:send, _}, 50

    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => load_id, "result" => %{}}))
    assert %{"id" => 2} = client_reply!(other)
  end

  test "a notice with no session reaches every client on the agent" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()
    {other, other_id} = spawn_client()
    call(other_id, "runtime/select", %{"name" => "lab"}, 1)
    client_reply!(other)

    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"update" => %{}}}))
    assert %{"method" => "session/update"} = reply!()
    assert %{"method" => "session/update"} = client_reply!(other)
  end

  test "a permission goes only to the phone that prompted" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    {other, other_id} = spawn_client()
    call(other_id, "session/load", %{"sessionId" => "ses_1", "cwd" => "/tmp", "mcpServers" => []}, 1)
    assert {:agent, %{"id" => load_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => load_id, "result" => %{}}))
    client_reply!(other)

    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "go"}]}, 2)
    assert %{"method" => "session/update"} = reply!()
    assert %{"method" => "session/update"} = client_reply!(other)
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "perm",
      "method" => "session/request_permission",
      "params" => %{"sessionId" => "ses_1", "toolCall" => %{"title" => "run"}, "options" => []}
    }))
    mine = reply!()
    refute_receive {^other, {:send, _}}, 50

    Pont.Plane.client_frame(other_id, Jason.encode!(%{"jsonrpc" => "2.0", "id" => mine["id"], "result" => %{"outcome" => "stolen"}}))
    refute_receive {:agent, _}, 50

    Pont.Plane.client_frame(id, Jason.encode!(%{"jsonrpc" => "2.0", "id" => mine["id"], "result" => %{"outcome" => "allow"}}))
    assert {:agent, %{"id" => "perm", "result" => %{"outcome" => "allow"}}} = from_agent!()
  end

  test "a permission during load goes only to the phone that is loading" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    {other, other_id} = spawn_client()
    call(other_id, "session/load", %{"sessionId" => "ses_9", "cwd" => "/tmp", "mcpServers" => []}, 1)
    assert {:agent, %{"method" => "session/load"}} = from_agent!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "perm",
      "method" => "session/request_permission",
      "params" => %{"sessionId" => "ses_9"}
    }))
    assert %{"method" => "session/request_permission"} = client_reply!(other)
    refute_receive {:send, _}, 50
  end

  test "an error answer is forwarded, and a permission with no issuer is declined" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "go"}]}, 1)
    assert %{"method" => "session/update"} = reply!()
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "perm",
      "method" => "session/request_permission",
      "params" => %{"sessionId" => "ses_1"}
    }))
    ask = reply!()
    Pont.Plane.client_frame(id, Jason.encode!(%{"jsonrpc" => "2.0", "id" => ask["id"], "error" => %{"code" => 1, "message" => "no"}}))
    assert {:agent, %{"id" => "perm", "error" => %{"message" => "no"}}} = from_agent!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "lonely",
      "method" => "session/request_permission",
      "params" => %{"sessionId" => "nobody"}
    }))
    assert {:agent, %{"id" => "lonely", "error" => %{"message" => "no app is attached to this session"}}} = from_agent!()
  end

  test "a reply that nobody asked for is dropped, and a non-json agent frame is dropped" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    Pont.Plane.client_frame(id, ~s({"jsonrpc":"2.0","id":4,"result":{}}))
    refute_receive {:send, _}, 50
    Pont.Plane.agent_frame("lab", "not-json\n")
    refute_receive _, 50
  end

  test "the agent disconnecting fails the prompt and the queue" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "a"}]}, 8)
    reply!()
    from_agent!()
    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "b"}]}, 9)
    Pont.Plane.runtime_down("lab")
    assert %{"id" => 8, "error" => %{"message" => "runtime disconnected"}} = reply!()
    assert %{"id" => 9, "error" => %{"message" => "runtime disconnected"}} = reply!()
    Pont.Plane.runtime_reset("missing")
    refute_receive {:send, _}, 50
  end

  test "a client leaving drops it, and an unknown down is ignored" do
    {pid, id} = spawn_client()
    agent!("lab")
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    {:agent, %{"id" => agent_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"sessionId" => "ses_1"}}))
    client_reply!(pid)

    send(Pont.Plane, {:DOWN, make_ref(), :process, self(), :normal})
    Process.exit(pid, :kill)
    Process.sleep(30)

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "ses_1", "update" => %{}}
    }))
    refute_receive {^pid, {:send, _}}, 50
  end

  test "a prompt queued for a client that then leaves the runtime is skipped" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "a"}]}, 5)
    reply!()
    assert {:agent, first} = from_agent!()
    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "b"}]}, 7)

    agent!("other")
    call(id, "runtime/select", %{"name" => "other"}, 6)
    reply!()

    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => first["id"], "result" => %{"stopReason" => "end_turn"}}))
    assert %{"id" => 5} = reply!()
    refute_receive {:send, _}, 50
    refute_receive {:agent, %{"method" => "session/prompt"}}, 50
  end

  test "a dead runtime answers the next call with runtime is down" do
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
    pid = agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()
    Process.exit(pid, :kill)
    Process.sleep(30)
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 2)
    assert %{"error" => %{"message" => "runtime is down"}} = reply!()
  end

  test "a permission for a dead issuer is declined" do
    agent!("lab")
    {pid, id} = spawn_client()
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    {:agent, %{"id" => agent_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"sessionId" => "ses_1"}}))
    assert %{"result" => %{"sessionId" => "ses_1"}} = client_reply!(pid)

    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "go"}]}, 2)
    assert %{"method" => "session/update"} = client_reply!(pid)
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

    Process.exit(pid, :kill)
    Process.sleep(30)

    Pont.Plane.agent_frame("lab", Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "perm",
      "method" => "session/request_permission",
      "params" => %{"sessionId" => "ses_1"}
    }))
    assert {:agent, %{"id" => "perm", "error" => %{"message" => "no app is attached to this session"}}} = from_agent!()
  end

  test "a subject only sees the runtimes it is allowed to use" do
    previous = Application.get_env(:pont, :access)
    Application.put_env(:pont, :access, Pont.PlaneTest.Gate)

    on_exit(fn ->
      if previous, do: Application.put_env(:pont, :access, previous), else: Application.delete_env(:pont, :access)
    end)

    agent!("hidden")
    agent!("lab")
    id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "ada", role: :user})
    call(id, "runtime/list", %{}, 1)
    assert %{"result" => %{"runtimes" => [%{"name" => "lab"}]}} = reply!()

    call(id, "runtime/select", %{"name" => "hidden"}, 2)
    assert %{"error" => %{"message" => "runtime is not allowed"}} = reply!()
  end

  defp agent!(name) do
    parent = self()
    pid = spawn(fn -> agent_loop(parent) end)
    :ok = Pont.Registry.register(pid, %Pont.Registry.Uplink{name: name, label: name}, %Pont.Access.Subject{id: "admin", role: :admin})
    pid
  end

  defp agent_loop(parent) do
    receive do
      {:send, json} ->
        send(parent, {:agent, Jason.decode!(json)})
        agent_loop(parent)
    end
  end

  defp spawn_client do
    parent = self()
    pid = spawn(fn ->
      id = Pont.Plane.register(self(), %Pont.Access.Subject{id: "admin", role: :admin})
      send(parent, {:ready, id})
      client_loop(parent)
    end)
    assert_receive {:ready, id}
    {pid, id}
  end

  defp client_loop(parent) do
    receive do
      {:send, json} ->
        send(parent, {self(), {:send, json}})
        client_loop(parent)
    end
  end

  defp call(id, method, params, req_id) do
    Pont.Plane.client_frame(id, Jason.encode!(%{"jsonrpc" => "2.0", "id" => req_id, "method" => method, "params" => params}))
  end

  defp reply! do
    assert_receive {:send, json}, 500
    Jason.decode!(json)
  end

  defp from_agent! do
    assert_receive {:agent, message}, 500
    {:agent, message}
  end

  defp client_reply!(pid) do
    assert_receive {^pid, {:send, json}}, 500
    Jason.decode!(json)
  end

  defp open_session!(id, session_id) do
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, session_id)
    {:agent, %{"id" => agent_id}} = from_agent!()
    Pont.Plane.agent_frame("lab", Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"sessionId" => session_id}}))
    assert %{"result" => %{"sessionId" => ^session_id}} = reply!()
  end
end
