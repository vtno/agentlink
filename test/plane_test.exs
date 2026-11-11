defmodule AgentLink.PlaneTest do
  use ExUnit.Case, async: false

  defmodule Gate do
    @behaviour AgentLink.Access

    def authenticate(_conn), do: {:ok, %AgentLink.Access.Subject{id: "ada", role: :user}}
    def allowed?(_subject, "hidden"), do: false
    def allowed?(%AgentLink.Access.Subject{}, runtime) when is_binary(runtime), do: true
    def claim(_subject, _name), do: :ok
    def prepare(_mode), do: {:ok, ""}
  end

  setup do
    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane.Sessions)
    start_supervised!(AgentLink.Plane)
    :ok
  end

  test "a batch is rejected and garbage is a parse error" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    AgentLink.Plane.client_frame(id, "[1]\nnot-json")
    assert %{"error" => %{"code" => -32600}} = reply!()
    assert %{"error" => %{"code" => -32700}} = reply!()
  end

  test "a message with no method is ignored" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    AgentLink.Plane.client_frame(id, ~s({"jsonrpc":"2.0","id":1}))
    refute_receive {:send, _}, 50
  end

  test "runtime list and select" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
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
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    AgentLink.Plane.client_frame(id, ~s({"jsonrpc":"2.0","method":"runtime/list"}))
    refute_receive {:send, _}, 50
  end

  test "no runtime, one runtime is chosen, two runtimes must be chosen" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    assert %{"error" => %{"message" => "no runtime connected"}} = reply!()

    agent!("only")
    call(id, "initialize", %{}, 2)
    assert {:agent, %{"method" => "initialize"}} = from_agent!()

    other = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("other")
    call(other, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 3)
    assert %{"error" => %{"message" => "select a runtime"}} = reply!()
  end

  test "initialize is cached and a second caller waits for the same reply" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()

    {other, other_id} = spawn_client()
    call(id, "initialize", %{}, 2)
    assert {:agent, %{"id" => agent_id}} = from_agent!()
    call(other_id, "initialize", %{}, 3)

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{"ok" => true}})
    )

    assert %{"id" => 2, "result" => %{"ok" => true}} = reply!()
    assert %{"id" => 3, "result" => %{"ok" => true}} = client_reply!(other)

    call(id, "initialize", %{}, 4)
    assert %{"id" => 4, "result" => %{"ok" => true}} = reply!()
    refute_receive {:agent, _}, 50
  end

  test "fs and terminal go only to the client that advertised them" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()

    caps =
      initialize!(id, 2, %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => true},
        "terminal" => true
      })

    assert caps == %{
             "fs" => %{"readTextFile" => true, "writeTextFile" => true},
             "terminal" => true
           }

    {other, other_id} = spawn_client()
    call(other_id, "runtime/select", %{"name" => "lab"}, 1)
    assert %{"id" => 1} = client_reply!(other)

    call(
      other_id,
      "initialize",
      %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{"fs" => false, "terminal" => false},
        "clientInfo" => %{"name" => "acp-ui", "version" => "0.1.0"}
      },
      2
    )

    assert %{"id" => 2, "result" => _} = client_reply!(other)
    refute_receive {:agent, _}, 50

    call(other_id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 3)
    assert {:agent, %{"id" => new_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => new_id,
        "result" => %{"sessionId" => "ses_web"}
      })
    )

    assert %{"result" => %{"sessionId" => "ses_web"}} = client_reply!(other)

    call(
      other_id,
      "session/prompt",
      %{"sessionId" => "ses_web", "prompt" => [%{"type" => "text", "text" => "go"}]},
      4
    )

    assert %{"method" => "session/update"} = client_reply!(other)
    assert {:agent, %{"id" => prompt_id, "method" => "session/prompt"}} = from_agent!()

    agent_ask("ses_web", "read", "fs/read_text_file")
    agent_ask("ses_web", "write", "fs/write_text_file")
    agent_ask("ses_web", "term", "terminal/create")
    agent_ask("ses_web", "perm", "session/request_permission")
    unsupported!("read")
    unsupported!("write")
    unsupported!("term")
    assert %{"method" => "session/request_permission"} = client_reply!(other)
    refute_receive {^other, {:send, _}}, 50
    refute_receive {:send, _}, 50

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => prompt_id,
        "result" => %{"stopReason" => "end_turn"}
      })
    )

    assert %{"id" => 4} = client_reply!(other)
    assert %{"method" => "session/update"} = client_reply!(other)

    open_session!(id, "ses_zed")
    prompt!(id, "ses_zed", 5)

    agent_ask("ses_zed", "read", "fs/read_text_file")
    agent_ask("ses_zed", "write", "fs/write_text_file")
    agent_ask("ses_zed", "term", "terminal/create")
    assert %{"method" => "fs/read_text_file"} = reply!()
    assert %{"method" => "fs/write_text_file"} = reply!()
    assert %{"method" => "terminal/create"} = reply!()
    refute_receive {:agent, _}, 50
    refute_receive {^other, {:send, _}}, 50
  end

  test "fs read and write are gated on their own flags" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")

    initialize!(id, 1, %{
      "fs" => %{"readTextFile" => true, "writeTextFile" => false},
      "terminal" => false
    })

    open_session!(id, "ses_1")
    prompt!(id, "ses_1", 2)

    agent_ask("ses_1", "read", "fs/read_text_file")
    agent_ask("ses_1", "write", "fs/write_text_file")
    agent_ask("ses_1", "term", "terminal/create")
    agent_ask("ses_1", "other", "fs/read_bytes")
    assert %{"method" => "fs/read_text_file"} = reply!()
    unsupported!("write")
    unsupported!("term")
    unsupported!("other")
    refute_receive {:send, _}, 50
  end

  test "a failed initialize is not cached" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "initialize", %{}, 1)
    assert {:agent, %{"id" => agent_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "error" => %{"code" => 1, "message" => "no"}
      })
    )

    assert %{"id" => 1, "error" => %{"message" => "no"}} = reply!()

    call(id, "initialize", %{}, 2)
    assert {:agent, %{"method" => "initialize"}} = from_agent!()
  end

  test "session new opens the directory and a failed new does not" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    assert {:agent, %{"id" => agent_id, "method" => "session/new"}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "error" => %{"code" => 1, "message" => "no"}
      })
    )

    assert %{"error" => _} = reply!()
    assert listed(id, 9) == []

    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 2)
    assert {:agent, %{"id" => agent_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"sessionId" => "ses_1"}
      })
    )

    assert %{"result" => %{"sessionId" => "ses_1"}} = reply!()
    assert [%{"sessionId" => "ses_1", "cwd" => "/tmp"}] = listed(id, 8)
    assert :sys.get_state(AgentLink.Plane).clients[id].session_id == "ses_1"
  end

  test "prompts run one at a time and the stop is broadcast" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "hi"}]},
      10
    )

    assert %{"method" => "session/update"} = reply!()
    assert {:agent, %{"id" => first, "method" => "session/prompt"}} = from_agent!()

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "next"}]},
      11
    )

    refute_receive {:agent, _}, 50

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => first,
        "result" => %{"stopReason" => "end_turn"}
      })
    )

    assert %{"id" => 10, "result" => %{"stopReason" => "end_turn"}} = reply!()
    assert %{"params" => %{"update" => %{"_meta" => %{"stopReason" => "end_turn"}}}} = reply!()
    assert {:agent, %{"id" => second, "method" => "session/prompt"}} = from_agent!()
    assert %{"method" => "session/update"} = reply!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => second,
        "error" => %{"code" => 1, "message" => "boom"}
      })
    )

    assert %{"id" => 11, "error" => _} = reply!()
    assert %{"params" => %{"update" => %{"_meta" => %{"stopReason" => "error"}}}} = reply!()
  end

  test "a prompt with no text and no session still runs, and a cancel is not queued" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "session/prompt", %{"prompt" => []}, 1)
    assert {:agent, %{"method" => "session/prompt", "id" => agent_id}} = from_agent!()
    refute_receive {:send, _}, 50

    AgentLink.Plane.client_frame(
      id,
      ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"x"}})
    )

    assert {:agent, %{"method" => "session/cancel"}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => agent_id, "result" => %{}})
    )

    assert %{"id" => 1} = reply!()
    refute_receive {:send, _}, 50
  end

  test "a live update goes only to clients that have that session open" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    {other, other_id} = spawn_client()
    call(other_id, "runtime/select", %{"name" => "lab"}, 1)
    assert %{"id" => 1} = client_reply!(other)

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "yo"}
          }
        }
      })
    )

    assert %{"method" => "session/update"} = reply!()
    _ = :sys.get_state(AgentLink.Plane)
    sync_client(other)
    refute_received {^other, {:send, _}}

    call(
      other_id,
      "session/load",
      %{"sessionId" => "ses_1", "cwd" => "/tmp", "mcpServers" => []},
      2
    )

    assert %{"params" => %{"update" => %{"content" => %{"text" => "yo"}}}} = client_reply!(other)
    assert %{"id" => 2, "result" => %{}} = client_reply!(other)
    sync_agent()
    refute_received {:agent, %{"method" => "session/load"}}

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{"sessionUpdate" => "agent_message_chunk"}
        }
      })
    )

    assert %{"method" => "session/update"} = reply!()
    assert %{"method" => "session/update"} = client_reply!(other)
  end

  test "a notice with no session reaches every client on the agent" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()
    {other, other_id} = spawn_client()
    call(other_id, "runtime/select", %{"name" => "lab"}, 1)
    client_reply!(other)

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"update" => %{}}
      })
    )

    assert %{"method" => "session/update"} = reply!()
    assert %{"method" => "session/update"} = client_reply!(other)
  end

  test "a permission goes only to the phone that prompted" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    {other, other_id} = spawn_client()

    call(
      other_id,
      "session/load",
      %{"sessionId" => "ses_1", "cwd" => "/tmp", "mcpServers" => []},
      1
    )

    assert %{"id" => 1, "result" => %{}} = client_reply!(other)
    sync_agent()
    refute_received {:agent, %{"method" => "session/load"}}

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "go"}]},
      2
    )

    assert %{"method" => "session/update"} = reply!()
    assert %{"method" => "session/update"} = client_reply!(other)
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "perm",
        "method" => "session/request_permission",
        "params" => %{"sessionId" => "ses_1", "toolCall" => %{"title" => "run"}, "options" => []}
      })
    )

    mine = reply!()
    refute_receive {^other, {:send, _}}, 50

    AgentLink.Plane.client_frame(
      other_id,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => mine["id"],
        "result" => %{"outcome" => "stolen"}
      })
    )

    refute_receive {:agent, _}, 50

    AgentLink.Plane.client_frame(
      id,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => mine["id"],
        "result" => %{"outcome" => "allow"}
      })
    )

    assert {:agent, %{"id" => "perm", "result" => %{"outcome" => "allow"}}} = from_agent!()
  end

  test "an unknown load or resume is session not found and is not forwarded" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")

    call(id, "session/load", %{"sessionId" => "missing", "cwd" => "/tmp", "mcpServers" => []}, 2)

    assert %{"id" => 2, "error" => %{"code" => -32002, "message" => "session not found"}} =
             reply!()

    call(id, "session/resume", %{"sessionId" => "missing"}, 3)

    assert %{"id" => 3, "error" => %{"code" => -32002, "message" => "session not found"}} =
             reply!()

    call(id, "session/load", %{}, 4)

    assert %{"id" => 4, "error" => %{"code" => -32602, "message" => "sessionId is required"}} =
             reply!()

    sync_agent()
    refute_received {:agent, %{"method" => "session/load"}}
    refute_received {:agent, %{"method" => "session/resume"}}
  end

  test "an error answer is forwarded, and a permission with no issuer is declined" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "go"}]},
      1
    )

    assert %{"method" => "session/update"} = reply!()
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "perm",
        "method" => "session/request_permission",
        "params" => %{"sessionId" => "ses_1"}
      })
    )

    ask = reply!()

    AgentLink.Plane.client_frame(
      id,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => ask["id"],
        "error" => %{"code" => 1, "message" => "no"}
      })
    )

    assert {:agent, %{"id" => "perm", "error" => %{"message" => "no"}}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "lonely",
        "method" => "session/request_permission",
        "params" => %{"sessionId" => "nobody"}
      })
    )

    assert {:agent,
            %{"id" => "lonely", "error" => %{"message" => "no app is attached to this session"}}} =
             from_agent!()
  end

  test "a reply that nobody asked for is dropped, and a non-json agent frame is dropped" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    AgentLink.Plane.client_frame(id, ~s({"jsonrpc":"2.0","id":4,"result":{}}))
    refute_receive {:send, _}, 50
    AgentLink.Plane.agent_frame("lab", "not-json\n")
    refute_receive _, 50
  end

  test "the agent disconnecting fails the prompt and the queue" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "a"}]},
      8
    )

    reply!()
    from_agent!()

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "b"}]},
      9
    )

    AgentLink.Plane.runtime_down("lab")
    assert %{"id" => 8, "error" => %{"message" => "runtime disconnected"}} = reply!()
    assert %{"id" => 9, "error" => %{"message" => "runtime disconnected"}} = reply!()
    AgentLink.Plane.runtime_reset("missing")
    refute_receive {:send, _}, 50
  end

  test "a client leaving drops it, and an unknown down is ignored" do
    {pid, id} = spawn_client()
    agent!("lab")
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    {:agent, %{"id" => agent_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"sessionId" => "ses_1"}
      })
    )

    client_reply!(pid)

    send(AgentLink.Plane, {:DOWN, make_ref(), :process, self(), :normal})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => "ses_1", "update" => %{}}
      })
    )

    refute_receive {^pid, {:send, _}}, 50
  end

  test "a prompt queued for a client that then leaves the runtime is skipped" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "a"}]},
      5
    )

    reply!()
    assert {:agent, first} = from_agent!()

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "b"}]},
      7
    )

    agent!("other")
    call(id, "runtime/select", %{"name" => "other"}, 6)
    reply!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => first["id"],
        "result" => %{"stopReason" => "end_turn"}
      })
    )

    assert %{"id" => 5} = reply!()

    assert %{
             "params" => %{"update" => %{"sessionUpdate" => "session_info_update"}}
           } = reply!()

    refute_receive {:send, _}, 50
    refute_receive {:agent, %{"method" => "session/prompt"}}, 50
  end

  test "a dead runtime answers the next call with runtime is down" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    pid = agent!("lab")
    call(id, "runtime/select", %{"name" => "lab"}, 1)
    reply!()
    Process.exit(pid, :kill)
    Process.sleep(30)
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 2)
    assert %{"error" => %{"message" => "runtime is down"}} = reply!()
  end

  test "a question delivered before its client disconnects is declined and the prompt queue resumes" do
    agent!("lab")

    survivor =
      AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})

    open_session!(survivor, "ses_1")
    {pid, id} = spawn_client()
    load_client_session!(pid, id, "ses_1")
    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 1)
    assert {:agent, %{"method" => "session/prompt", "id" => prompt_id}} = from_agent!()

    agent_ask("ses_1", "perm", "session/request_permission")
    assert %{"method" => "session/request_permission"} = client_reply!(pid)

    call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 3)
    call(survivor, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 2)
    disconnect_client!(pid, id)

    assert {:agent,
            %{
              "id" => "perm",
              "error" => %{"code" => -32000, "message" => "no app is attached to this session"}
            }} = from_agent!()

    assert [%{client_id: ^survivor}] =
             :queue.to_list(:sys.get_state(AgentLink.Plane).slots["lab"].prompt_queue)

    refute_receive {:agent, %{"method" => "session/prompt"}}, 50

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => prompt_id,
        "result" => %{"stopReason" => "end_turn"}
      })
    )

    assert %{"params" => %{"update" => %{"_meta" => %{"stopReason" => "end_turn"}}}} = reply!()
    assert {:agent, %{"method" => "session/prompt", "id" => next_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => next_id,
        "result" => %{"stopReason" => "end_turn"}
      })
    )

    assert %{"id" => 2, "result" => %{"stopReason" => "end_turn"}} = reply!()
    assert %{"method" => "session/update"} = reply!()
    slot = :sys.get_state(AgentLink.Plane).slots["lab"]
    assert slot.fan_pending == %{}
    assert slot.agent_pending == %{}
    refute slot.prompt_inflight
  end

  for order <- [:reply_first, :down_first] do
    test "a client reply racing DOWN is handled once: #{order}" do
      agent!("lab")
      {pid, id} = spawn_client()
      call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 1)
      assert {:agent, %{"method" => "session/prompt"}} = from_agent!()
      agent_ask("ses_1", "perm", "session/request_permission")
      assert %{"id" => fan_id} = client_reply!(pid)

      response =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => fan_id, "result" => %{"outcome" => "allow"}})

      case unquote(order) do
        :reply_first ->
          AgentLink.Plane.client_frame(id, response)
          assert :sys.get_state(AgentLink.Plane).slots["lab"].fan_pending == %{}
          disconnect_client!(pid, id)
          assert {:agent, %{"id" => "perm", "result" => %{"outcome" => "allow"}}} = from_agent!()

        :down_first ->
          disconnect_client!(pid, id)
          AgentLink.Plane.client_frame(id, response)
          assert :sys.get_state(AgentLink.Plane).slots["lab"].fan_pending == %{}
          assert {:agent, %{"id" => "perm", "error" => %{"code" => -32000}}} = from_agent!()
      end

      assert Process.alive?(Process.whereis(AgentLink.Plane))
      refute_receive {:agent, _}, 50
    end
  end

  test "disconnecting a peer leaves the opener's prompt and session" do
    agent!("lab")

    survivor =
      AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})

    initialize!(survivor, 1, %{})
    open_session!(survivor, "ses_1")
    {pid, id} = spawn_client()

    call(
      id,
      "initialize",
      %{"clientCapabilities" => %{"fs" => %{"readTextFile" => true}, "terminal" => true}},
      1
    )

    assert %{"id" => 1, "result" => _} = client_reply!(pid)
    load_client_session!(pid, id, "ses_1")

    call(id, "session/load", %{"sessionId" => "ses_2", "cwd" => "/tmp", "mcpServers" => []}, 2)

    assert %{"id" => 2, "error" => %{"code" => -32002, "message" => "session not found"}} =
             client_reply!(pid)

    sync_agent()
    refute_received {:agent, %{"method" => "session/load"}}

    call(survivor, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 3)
    assert {:agent, %{"method" => "session/prompt", "id" => prompt_id}} = from_agent!()

    agent_ask("ses_1", "perm", "session/request_permission")
    assert %{"id" => fan_id, "method" => "session/request_permission"} = reply!()
    disconnect_client!(pid, id)

    slot = :sys.get_state(AgentLink.Plane).slots["lab"]
    assert %{^fan_id => %{client_id: ^survivor}} = slot.fan_pending
    assert map_size(slot.fan_pending) == 1
    assert slot.prompt_inflight

    AgentLink.Plane.client_frame(
      survivor,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => fan_id, "result" => %{}})
    )

    assert {:agent, %{"id" => "perm", "result" => %{}}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => prompt_id,
        "result" => %{"stopReason" => "end_turn"}
      })
    )

    assert %{"id" => 3, "result" => _} = reply!()
    assert %{"method" => "session/update"} = reply!()
    state = :sys.get_state(AgentLink.Plane)
    assert state.clients[survivor].session_id == "ses_1"
    assert state.slots["lab"].agent_pending == %{}
    refute state.slots["lab"].prompt_inflight
    refute_receive {:agent, _}, 50
  end

  for leaving <- [:issuer, :waiter] do
    test "disconnecting an initialize #{leaving} removes only its waiters and preserves the shared initialize" do
      agent!("lab")
      {pid, id} = spawn_client()

      survivor =
        AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})

      {first, second} = if unquote(leaving) == :issuer, do: {id, survivor}, else: {survivor, id}
      call(first, "initialize", %{}, 1)
      assert {:agent, %{"method" => "initialize", "id" => init_id}} = from_agent!()
      call(second, "initialize", %{}, 2)
      assert length(:sys.get_state(AgentLink.Plane).slots["lab"].init_waiters) == 2
      call(id, "initialize", %{}, 3)
      assert length(:sys.get_state(AgentLink.Plane).slots["lab"].init_waiters) == 3
      disconnect_client!(pid, id)

      slot = :sys.get_state(AgentLink.Plane).slots["lab"]
      assert [%{client_id: ^survivor, id: survivor_req_id}] = slot.init_waiters
      assert slot.init_sent

      AgentLink.Plane.agent_frame(
        "lab",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => init_id, "result" => %{"ok" => true}})
      )

      assert %{"id" => ^survivor_req_id, "result" => %{"ok" => true}} = reply!()
      call(survivor, "initialize", %{}, 4)
      assert %{"id" => 4, "result" => %{"ok" => true}} = reply!()
      assert :sys.get_state(AgentLink.Plane).slots["lab"].init_waiters == []
      refute_receive {:agent, _}, 50
    end
  end

  for order <- [:cancel_reply_first, :down_first] do
    test "disconnect and a cancelled prompt response do not release the next prompt early: #{order}" do
      agent!("lab")
      {pid, id} = spawn_client()

      survivor =
        AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})

      call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 1)
      assert {:agent, %{"method" => "session/prompt", "id" => prompt_id}} = from_agent!()
      agent_ask("ses_1", "perm", "session/request_permission")
      assert %{"method" => "session/request_permission"} = client_reply!(pid)
      call(survivor, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 2)

      AgentLink.Plane.client_frame(
        survivor,
        ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"ses_1"}})
      )

      assert {:agent, %{"method" => "session/cancel"}} = from_agent!()

      cancelled =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => prompt_id,
          "result" => %{"stopReason" => "cancelled"}
        })

      case unquote(order) do
        :cancel_reply_first ->
          AgentLink.Plane.agent_frame("lab", cancelled)
          assert %{"id" => 1, "result" => %{"stopReason" => "cancelled"}} = client_reply!(pid)
          disconnect_client!(pid, id)

        :down_first ->
          disconnect_client!(pid, id)
          refute_receive {:agent, %{"method" => "session/prompt"}}, 50
          AgentLink.Plane.agent_frame("lab", cancelled)
      end

      # The two agent writes can arrive in either order relative to one another.
      assert_receive {:agent, %{"id" => "perm", "error" => %{"code" => -32000}}}, 500
      assert_receive {:agent, %{"method" => "session/prompt", "id" => next_id}}, 500
      slot = :sys.get_state(AgentLink.Plane).slots["lab"]
      assert slot.prompt_inflight
      refute Map.has_key?(slot.agent_pending, prompt_id)
      assert %{client_id: ^survivor} = slot.agent_pending[next_id]
      assert slot.fan_pending == %{}

      AgentLink.Plane.agent_frame(
        "lab",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => next_id,
          "result" => %{"stopReason" => "end_turn"}
        })
      )

      assert %{"id" => 2, "result" => _} = reply!()
      refute :sys.get_state(AgentLink.Plane).slots["lab"].prompt_inflight
      refute_receive {:agent, _}, 50
    end
  end

  test "client cleanup covers slots left behind by runtime selection" do
    agent!("lab")
    agent!("other")
    {pid, id} = spawn_client()

    for name <- ["lab", "other"] do
      call(id, "runtime/select", %{"name" => name}, 1)
      assert %{"id" => 1} = client_reply!(pid)
      call(id, "initialize", %{}, 2)
      assert {:agent, %{"method" => "initialize"}} = from_agent!()
      call(id, "session/prompt", %{"sessionId" => "ses_1", "prompt" => []}, 3)
      assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

      AgentLink.Plane.agent_frame(
        name,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => name,
          "method" => "session/request_permission",
          "params" => %{"sessionId" => "ses_1"}
        })
      )

      assert %{"method" => "session/request_permission"} = client_reply!(pid)
    end

    disconnect_client!(pid, id)

    for name <- ["lab", "other"] do
      assert_receive {:agent, %{"id" => ^name, "error" => %{"code" => -32000}}}, 500
    end

    for {name, slot} <- :sys.get_state(AgentLink.Plane).slots do
      assert slot.fan_pending == %{}
      assert slot.init_waiters == []

      for {req_id, pending} <- slot.agent_pending do
        result = if pending.kind == :prompt, do: %{"stopReason" => "end_turn"}, else: %{}

        AgentLink.Plane.agent_frame(
          name,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => req_id, "result" => result})
        )
      end
    end

    for slot <- Map.values(:sys.get_state(AgentLink.Plane).slots) do
      assert slot.agent_pending == %{}
      refute slot.prompt_inflight
    end
  end

  test "a permission for a dead issuer is declined" do
    agent!("lab")
    {pid, id} = spawn_client()
    call(id, "session/new", %{"cwd" => "/tmp", "mcpServers" => []}, 1)
    {:agent, %{"id" => agent_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"sessionId" => "ses_1"}
      })
    )

    assert %{"result" => %{"sessionId" => "ses_1"}} = client_reply!(pid)

    call(
      id,
      "session/prompt",
      %{"sessionId" => "ses_1", "prompt" => [%{"type" => "text", "text" => "go"}]},
      2
    )

    assert %{"method" => "session/update"} = client_reply!(pid)
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()

    Process.exit(pid, :kill)
    Process.sleep(30)

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "perm",
        "method" => "session/request_permission",
        "params" => %{"sessionId" => "ses_1"}
      })
    )

    assert {:agent,
            %{"id" => "perm", "error" => %{"message" => "no app is attached to this session"}}} =
             from_agent!()
  end

  test "a subject only sees the runtimes it is allowed to use" do
    previous = Application.get_env(:agent_link, :access)
    Application.put_env(:agent_link, :access, AgentLink.PlaneTest.Gate)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :access, previous),
        else: Application.delete_env(:agent_link, :access)
    end)

    agent!("hidden")
    agent!("lab")
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "ada", role: :user})
    call(id, "runtime/list", %{}, 1)
    assert %{"result" => %{"runtimes" => [%{"name" => "lab"}]}} = reply!()

    call(id, "runtime/select", %{"name" => "hidden"}, 2)
    assert %{"error" => %{"message" => "runtime is not allowed"}} = reply!()
  end

  test "session list is answered from the directory" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_a", "/tmp")
    open_session!(id, "ses_b", "/elsewhere")

    call(id, "session/list", %{"cwd" => "/tmp"}, 1)

    assert %{"id" => 1, "result" => %{"sessions" => [%{"sessionId" => "ses_a", "cwd" => "/tmp"}]}} =
             reply!()

    call(id, "session/list", %{"cursor" => "nope"}, 2)
    assert %{"id" => 2, "error" => %{"code" => -32602, "message" => "invalid cursor"}} = reply!()

    call(id, "session/list", %{"cwd" => 1}, 3)
    assert %{"id" => 3, "error" => %{"code" => -32602, "message" => "invalid cwd"}} = reply!()

    call(id, "session/list", %{"cursor" => 1}, 4)
    assert %{"id" => 4, "error" => %{"code" => -32602, "message" => "invalid cursor"}} = reply!()

    AgentLink.Plane.client_frame(id, ~s({"jsonrpc":"2.0","method":"session/list"}))
    sync_agent()
    refute_received {:agent, %{"method" => "session/list"}}
    refute_received {:send, _}

    ids = Enum.map(1..51, &"page_#{&1}")

    for session_id <- ids do
      open_session!(id, session_id, "/pages")
    end

    call(id, "session/list", %{"cwd" => "/pages"}, 5)
    assert %{"id" => 5, "result" => %{"sessions" => first, "nextCursor" => cursor}} = reply!()
    assert length(first) == 50
    assert is_binary(cursor)

    call(id, "session/list", %{"cwd" => "/pages", "cursor" => cursor}, 6)
    assert %{"id" => 6, "result" => result} = reply!()
    assert length(result["sessions"]) == 1
    refute Map.has_key?(result, "nextCursor")

    got = Enum.map(first ++ result["sessions"], & &1["sessionId"])
    assert Enum.sort(got) == Enum.sort(ids)
    sync_agent()
    refute_received {:agent, %{"method" => "session/list"}}
  end

  test "load replays then answers and a later update reaches both clients" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    prompt!(id, "ses_1", 4)

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "yo"}
          }
        }
      })
    )

    assert %{"params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}} = reply!()

    {other, other_id} = spawn_client()

    call(
      other_id,
      "session/load",
      %{"sessionId" => "ses_1", "cwd" => "/tmp", "mcpServers" => []},
      1
    )

    assert %{
             "method" => "session/update",
             "params" => %{
               "sessionId" => "ses_1",
               "update" => %{"sessionUpdate" => "user_message_chunk"}
             }
           } = client_reply!(other)

    assert %{
             "method" => "session/update",
             "params" => %{
               "update" => %{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => %{"text" => "yo"}
               }
             }
           } = client_reply!(other)

    assert %{"id" => 1, "result" => %{}} = client_reply!(other)
    sync_agent()
    refute_received {:agent, %{"method" => "session/load"}}

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"text" => "next"}
          }
        }
      })
    )

    assert %{"params" => %{"update" => %{"content" => %{"text" => "next"}}}} = reply!()

    assert %{"params" => %{"update" => %{"content" => %{"text" => "next"}}}} =
             client_reply!(other)
  end

  test "resume joins with no replay" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    prompt!(id, "ses_1", 4)
    {other, other_id} = spawn_client()

    call(other_id, "session/resume", %{"sessionId" => "ses_1", "cwd" => "/tmp"}, 1)
    assert %{"id" => 1, "result" => %{}} = client_reply!(other)
    sync_agent()
    refute_received {:agent, %{"method" => "session/resume"}}

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{"sessionUpdate" => "agent_message_chunk"}
        }
      })
    )

    assert %{"method" => "session/update"} = reply!()
    assert %{"method" => "session/update"} = client_reply!(other)
    assert :sys.get_state(AgentLink.Plane).clients[other_id].session_id == "ses_1"
  end

  test "close drops one client and a later load still has the prompt" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    open_session!(id, "ses_2")
    {other, other_id} = spawn_client()
    load_client_session!(other, other_id, "ses_1")
    prompt!(id, "ses_1", 4)

    assert %{"params" => %{"update" => %{"sessionUpdate" => "user_message_chunk"}}} =
             client_reply!(other)

    call(id, "session/close", %{"sessionId" => "ses_1"}, 5)
    assert %{"id" => 5, "result" => %{}} = reply!()
    call(id, "session/close", %{"sessionId" => "ses_1"}, 6)
    assert %{"id" => 6, "result" => %{}} = reply!()
    call(id, "session/close", %{}, 7)

    assert %{"id" => 7, "error" => %{"code" => -32602, "message" => "sessionId is required"}} =
             reply!()

    sync_agent()
    refute_received {:agent, %{"method" => "session/close"}}
    assert :sys.get_state(AgentLink.Plane).clients[id].session_id == "ses_2"

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"text" => "after"}
          }
        }
      })
    )

    assert %{"params" => %{"update" => %{"content" => %{"text" => "after"}}}} =
             client_reply!(other)

    refute_received {:send, _}

    call(id, "session/load", %{"sessionId" => "ses_1", "cwd" => "/tmp", "mcpServers" => []}, 8)

    assert %{"params" => %{"update" => %{"sessionUpdate" => "user_message_chunk"}}} = reply!()
    assert %{"params" => %{"update" => %{"content" => %{"text" => "after"}}}} = reply!()
    assert %{"id" => 8, "result" => %{}} = reply!()

    assert Enum.map(listed(id, 9), & &1["sessionId"]) |> Enum.sort() == ["ses_1", "ses_2"]
  end

  test "one client receives updates for every session it opened" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    open_session!(id, "ses_2")
    assert :sys.get_state(AgentLink.Plane).clients[id].session_id == "ses_2"

    for session_id <- ["ses_1", "ses_2"] do
      AgentLink.Plane.agent_frame(
        "lab",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{
            "sessionId" => session_id,
            "update" => %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => %{"text" => session_id}
            }
          }
        })
      )

      assert %{"params" => %{"sessionId" => ^session_id}} = reply!()
    end
  end

  test "a non-map session update with a sessionId is dropped" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    open_session!(id, "ses_1")
    open_session!(id, "ses_2")
    assert :sys.get_state(AgentLink.Plane).clients[id].session_id == "ses_2"

    updates = [nil, "text", [1], 1]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for session_id <- ["ses_1", "ses_2"], update <- updates do
          AgentLink.Plane.agent_frame(
            "lab",
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "method" => "session/update",
              "params" => %{"sessionId" => session_id, "update" => update}
            })
          )
        end

        _ = :sys.get_state(AgentLink.Plane)
      end)

    for session_id <- ["ses_1", "ses_2"] do
      assert length(Regex.scan(~r/plane dropped session\/update session=#{session_id} /, log)) ==
               length(updates)
    end

    refute_received {:send, _}

    call(id, "session/load", %{"sessionId" => "ses_1", "cwd" => "/tmp", "mcpServers" => []}, 3)
    assert %{"id" => 3, "result" => %{}} = reply!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "ses_1",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"text" => "kept"}
          }
        }
      })
    )

    assert %{
             "params" => %{
               "sessionId" => "ses_1",
               "update" => %{"content" => %{"text" => "kept"}}
             }
           } =
             reply!()
  end

  test "session new without a cwd stores the workspace" do
    id = AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})
    agent!("lab")
    call(id, "session/new", %{}, 1)
    assert {:agent, %{"id" => agent_id, "method" => "session/new"}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"sessionId" => "ses_1"}
      })
    )

    assert %{"result" => %{"sessionId" => "ses_1"}} = reply!()
    cwd = AgentLink.Paths.workdir()
    assert [%{"sessionId" => "ses_1", "cwd" => ^cwd}] = listed(id, 2)
  end

  defp load_client_session!(pid, id, session_id) do
    call(id, "session/load", %{"sessionId" => session_id, "cwd" => "/tmp", "mcpServers" => []}, 1)
    assert %{"id" => 1, "result" => %{}} = client_reply!(pid)
  end

  defp disconnect_client!(pid, id) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_client_down!(id, System.monotonic_time(:millisecond) + 500)
  end

  defp await_client_down!(id, deadline) do
    if Map.has_key?(:sys.get_state(AgentLink.Plane).clients, id) do
      assert System.monotonic_time(:millisecond) < deadline, "plane did not process client DOWN"
      Process.sleep(1)
      await_client_down!(id, deadline)
    end
  end

  defp agent!(name) do
    parent = self()
    pid = spawn(fn -> agent_loop(parent) end)

    {:ok, ^name} =
      AgentLink.Registry.register(
        pid,
        %AgentLink.Registry.Uplink{name: name, label: name},
        %AgentLink.Access.Subject{id: "admin", role: :admin}
      )

    pid
  end

  defp agent_loop(parent) do
    receive do
      {:send, json} ->
        send(parent, {:agent, Jason.decode!(json)})
        agent_loop(parent)

      {:sync, from} ->
        send(from, {:synced, self()})
        agent_loop(parent)
    end
  end

  # Wait until the plane has handled earlier casts, then until the agent
  # process has forwarded every message already in its mailbox.
  defp sync_agent(name \\ "lab") do
    _ = :sys.get_state(AgentLink.Plane)
    pid = AgentLink.Registry.pid(name)
    send(pid, {:sync, self()})
    assert_receive {:synced, ^pid}, 500
  end

  defp spawn_client do
    parent = self()

    pid =
      spawn(fn ->
        id =
          AgentLink.Plane.register(self(), %AgentLink.Access.Subject{id: "admin", role: :admin})

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

      {:sync, from} ->
        send(from, {:synced, self()})
        client_loop(parent)
    end
  end

  defp sync_client(pid) do
    send(pid, {:sync, self()})
    assert_receive {:synced, ^pid}, 500
  end

  defp call(id, method, params, req_id) do
    AgentLink.Plane.client_frame(
      id,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => req_id, "method" => method, "params" => params})
    )
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

  defp initialize!(id, req_id, capabilities) do
    call(
      id,
      "initialize",
      %{"protocolVersion" => 1, "clientCapabilities" => capabilities},
      req_id
    )

    assert {:agent,
            %{
              "id" => agent_id,
              "method" => "initialize",
              "params" => %{"clientCapabilities" => caps}
            }} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"agentCapabilities" => %{}}
      })
    )

    assert %{"id" => ^req_id} = reply!()
    caps
  end

  defp prompt!(id, session_id, req_id) do
    call(
      id,
      "session/prompt",
      %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => "go"}]},
      req_id
    )

    assert %{"method" => "session/update"} = reply!()
    assert {:agent, %{"method" => "session/prompt"}} = from_agent!()
  end

  defp agent_ask(session_id, req_id, method) do
    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => req_id,
        "method" => method,
        "params" => %{"sessionId" => session_id}
      })
    )
  end

  defp unsupported!(req_id) do
    assert {:agent,
            %{
              "id" => ^req_id,
              "error" => %{"code" => -32601, "message" => "client does not support this method"}
            }} = from_agent!()
  end

  defp open_session!(id, session_id, cwd \\ "/tmp") do
    call(id, "session/new", %{"cwd" => cwd, "mcpServers" => []}, session_id)
    {:agent, %{"id" => agent_id}} = from_agent!()

    AgentLink.Plane.agent_frame(
      "lab",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => agent_id,
        "result" => %{"sessionId" => session_id}
      })
    )

    assert %{"result" => %{"sessionId" => ^session_id}} = reply!()
  end

  defp listed(id, req_id) do
    call(id, "session/list", %{}, req_id)
    assert %{"id" => ^req_id, "result" => %{"sessions" => sessions}} = reply!()
    sessions
  end
end
