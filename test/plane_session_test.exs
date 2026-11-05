defmodule AgentLink.Plane.SessionTest do
  use ExUnit.Case, async: true

  alias AgentLink.FakeSubscribe
  alias AgentLink.Frame
  alias AgentLink.Plane.Session

  test "two clients both receive each broadcast" do
    session = start!()
    assert {:ok, ada, []} = subscribe(session, "ada")
    assert {:ok, bea, []} = subscribe(session, "bea")

    assert :ok = Session.broadcast(session, user("one"))
    assert :ok = Session.broadcast(session, user("two"))

    assert FakeSubscribe.notified(ada) == [message("one"), message("two")]
    assert FakeSubscribe.notified(bea) == [message("one"), message("two")]
  end

  test "a late subscriber gets the replay and then live updates" do
    session = start!()
    assert {:ok, early, []} = subscribe(session, "early")
    assert :ok = Session.broadcast(session, user("one"))

    assert {:ok, late, replay} = subscribe(session, "late")
    assert replay == [message("one")]
    assert FakeSubscribe.notified(late) == []
    assert FakeSubscribe.notified(early) == [message("one")]

    assert :ok = Session.broadcast(session, user("two"))
    assert FakeSubscribe.notified(late) == [message("two")]
    assert FakeSubscribe.notified(early) == [message("one"), message("two")]
  end

  test "a late subscriber gets a truncated replay" do
    session = start!(history: [max_turns: 1])
    assert {:ok, early, []} = subscribe(session, "early")
    assert :ok = Session.broadcast(session, user("one"))
    assert :ok = Session.broadcast(session, user("two"))

    assert FakeSubscribe.notified(early) == [message("one"), message("two")]

    assert {:ok, late, replay} = subscribe(session, "late")

    assert replay == [note(1, 1, bytes(user("one"))), message("two")]

    assert FakeSubscribe.notified(late) == []
  end

  test "unsubscribe drops that subscription" do
    session = start!()
    {:ok, ada, []} = subscribe(session, "ada")
    {:ok, bea, []} = subscribe(session, "bea")

    assert :ok = Session.unsubscribe(session, ada)
    assert :ok = Session.unsubscribe(session, ada)
    assert :ok = Session.broadcast(session, user("after"))

    assert FakeSubscribe.notified(ada) == []
    assert FakeSubscribe.notified(bea) == [message("after")]
    assert Process.alive?(ada)
  end

  test "a dead client is dropped and the other client still receives" do
    session = start!()
    ada_client = client()
    {:ok, ada, []} = subscribe(session, "ada", ada_client)
    ref = Process.monitor(ada)
    {:ok, bea, []} = subscribe(session, "bea")

    Process.exit(ada_client, :kill)

    assert_receive {:DOWN, ^ref, :process, ^ada, :normal}
    assert :ok = Session.broadcast(session, user("after"))
    assert Process.alive?(session)
    assert FakeSubscribe.notified(bea) == [message("after")]
    assert Session.info(session)["title"] == "after"
  end

  test "info is the history row from the given clock" do
    session = start!(history: [clock: fn -> "2026-11-02T03:04:05Z" end])

    assert Session.info(session) == %{
             "sessionId" => "ses",
             "cwd" => "/tmp",
             "title" => nil,
             "updatedAt" => nil
           }

    assert :ok = Session.broadcast(session, user("hello"))

    assert Session.info(session) == %{
             "sessionId" => "ses",
             "cwd" => "/tmp",
             "title" => "hello",
             "updatedAt" => "2026-11-02T03:04:05Z"
           }
  end

  test "start_link and subscribe check their options" do
    assert_raise KeyError, fn -> Session.start_link(session_id: "ses", cwd: "/tmp") end
    assert_raise KeyError, fn -> Session.start_link(runtime: "lab", cwd: "/tmp") end
    assert_raise KeyError, fn -> Session.start_link(runtime: "lab", session_id: "ses") end

    assert_raise ArgumentError, ~r/:runtime/, fn ->
      Session.start_link(runtime: 1, session_id: "ses", cwd: "/tmp")
    end

    assert_raise ArgumentError, ~r/:history/, fn ->
      Session.start_link(runtime: "lab", session_id: "ses", cwd: "/tmp", history: %{})
    end

    assert_raise ArgumentError, ~r/:subscribe/, fn ->
      Session.start_link(runtime: "lab", session_id: "ses", cwd: "/tmp", subscribe: "nope")
    end

    assert_raise ArgumentError, ~r/:max_turns/, fn ->
      Session.start_link(runtime: "lab", session_id: "ses", cwd: "/tmp", history: [max_turns: 0])
    end

    session = start!()

    assert_raise ArgumentError, ~r/:client_pid/, fn ->
      Session.subscribe(session, client_pid: "nope", client_id: "ada")
    end

    assert_raise KeyError, fn ->
      Session.subscribe(session, client_id: "ada")
    end

    assert Process.alive?(session)
    assert :ok = Session.broadcast(session, user("still"))
    assert Session.info(session)["title"] == "still"
  end

  defp start!(opts \\ []) do
    history =
      Keyword.merge([clock: fn -> "2026-11-02T00:00:00Z" end], Keyword.get(opts, :history, []))

    opts =
      [runtime: "lab", session_id: "ses", cwd: "/tmp", subscribe: FakeSubscribe]
      |> Keyword.merge(opts)
      |> Keyword.put(:history, history)

    start_supervised!({Session, opts})
  end

  defp subscribe(session, client_id, client_pid \\ nil) do
    Session.subscribe(session,
      client_pid: client_pid || client(),
      client_id: client_id
    )
  end

  defp client do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp message(text) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "ses", "update" => user(text)}
    }
  end

  defp message_update(update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "ses", "update" => update}
    }
  end

  defp user(text) do
    %{"sessionUpdate" => "user_message_chunk", "content" => %{"type" => "text", "text" => text}}
  end

  defp note(dropped_turns, kept_turns, dropped_bytes) do
    message_update(%{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "Earlier turns were omitted."},
      "_meta" => %{
        "agentlink" => %{
          "history" => "truncated",
          "droppedTurns" => dropped_turns,
          "keptTurns" => kept_turns,
          "droppedBytes" => dropped_bytes
        }
      }
    })
  end

  defp bytes(update), do: byte_size(Frame.encode(update))
end
