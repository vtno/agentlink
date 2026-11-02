defmodule AgentLink.Plane.SessionsTest do
  use ExUnit.Case, async: false

  alias AgentLink.FakeSubscribe
  alias AgentLink.Frame
  alias AgentLink.Plane.Sessions

  # One more than the 50 row page in AgentLink.Plane.Sessions.
  @past_one_page 51

  setup do
    start_supervised!({Sessions, [subscribe: FakeSubscribe]})
    :ok
  end

  test "two clients share updates and a late client gets the replay" do
    assert :ok = Sessions.open("lab", "ses", "ada", self(), attrs("/tmp"))
    assert :ok = Sessions.broadcast("lab", "ses", user("one"))

    assert {:ok, replay} = Sessions.load("lab", "ses", "bea", self())
    assert replay == [message("ses", user("one"))]
    assert notified("bea", "ses") == []
    bea = subscription("bea", "ses")

    assert {:ok, ^replay} = Sessions.load("lab", "ses", "bea", self())
    assert subscription("bea", "ses") == bea
    assert length(subscriptions("ses")) == 2

    assert :ok = Sessions.broadcast("lab", "ses", user("two"))

    assert notified("ada", "ses") == [message("ses", user("one")), message("ses", user("two"))]
    assert notified("bea", "ses") == [message("ses", user("two"))]
  end

  test "load returns a truncated replay" do
    assert :ok = Sessions.open("lab", "ses", "ada", self(), attrs("/tmp", max_turns: 1))
    assert :ok = Sessions.broadcast("lab", "ses", user("one"))
    assert :ok = Sessions.broadcast("lab", "ses", user("two"))

    assert notified("ada", "ses") == [message("ses", user("one")), message("ses", user("two"))]

    assert {:ok, replay} = Sessions.load("lab", "ses", "bea", self())

    assert replay == [
             message("ses", note(1, 1, bytes(user("one")))),
             message("ses", user("two"))
           ]

    assert notified("bea", "ses") == []
  end

  test "resume subscribes and does not replay" do
    assert :ok = Sessions.open("lab", "ses", "ada", self(), attrs("/tmp"))
    assert :ok = Sessions.broadcast("lab", "ses", user("one"))

    assert :ok = Sessions.resume("lab", "ses", "bea", self())
    assert notified("bea", "ses") == []
    assert length(subscriptions("ses")) == 2

    assert :ok = Sessions.resume("lab", "ses", "bea", self())
    assert length(subscriptions("ses")) == 2

    assert :ok = Sessions.broadcast("lab", "ses", user("two"))
    assert notified("bea", "ses") == [message("ses", user("two"))]
  end

  test "a second open keeps the history and does not notify twice" do
    assert :ok = Sessions.open("lab", "ses", "ada", self(), attrs("/tmp"))
    assert :ok = Sessions.broadcast("lab", "ses", user("one"))

    assert :ok =
             Sessions.open("lab", "ses", "ada", self(), attrs("/elsewhere", max_turns: 1))

    assert length(subscriptions("ses")) == 1

    assert Sessions.list("lab").sessions == [
             %{
               "sessionId" => "ses",
               "cwd" => "/tmp",
               "title" => "one",
               "updatedAt" => "2026-11-02T00:00:00Z"
             }
           ]

    assert :ok = Sessions.broadcast("lab", "ses", user("two"))
    assert notified("ada", "ses") == [message("ses", user("one")), message("ses", user("two"))]

    assert {:ok, replay} = Sessions.load("lab", "ses", "bea", self())
    assert replay == [message("ses", user("one")), message("ses", user("two"))]
  end

  test "leave drops one client and keeps the session" do
    assert :ok = Sessions.open("lab", "ses", "ada", self(), attrs("/tmp"))
    assert {:ok, []} = Sessions.load("lab", "ses", "bea", self())
    assert :ok = Sessions.broadcast("lab", "ses", user("one"))

    ada = subscription("ada", "ses")
    bea = subscription("bea", "ses")
    session = session("ses")

    assert :ok = Sessions.leave("lab", "ses", "ada")
    refute Process.alive?(ada)
    assert Process.alive?(bea)
    assert Process.alive?(session)
    assert :ok = Sessions.leave("lab", "ses", "ada")

    assert :ok = Sessions.broadcast("lab", "ses", user("two"))
    assert notified("bea", "ses") == [message("ses", user("one")), message("ses", user("two"))]

    assert {:ok, replay} = Sessions.load("lab", "ses", "ada", self())
    assert replay == [message("ses", user("one")), message("ses", user("two"))]
  end

  test "disconnect drops every session for that client" do
    assert :ok = Sessions.open("lab", "one", "ada", self(), attrs("/tmp"))
    assert :ok = Sessions.open("lab", "two", "ada", self(), attrs("/tmp"))
    assert :ok = Sessions.open("lab", "one", "bea", self(), attrs("/tmp"))

    one = subscription("ada", "one")
    two = subscription("ada", "two")
    bea = subscription("bea", "one")

    assert :ok = Sessions.disconnect("ada")
    refute Process.alive?(one)
    refute Process.alive?(two)
    assert Process.alive?(bea)
    assert Process.alive?(session("one"))
    assert Process.alive?(session("two"))
    assert :ok = Sessions.disconnect("ada")

    assert :ok = Sessions.broadcast("lab", "one", user("later"))
    assert notified("bea", "one") == [message("one", user("later"))]
  end

  test "leave still returns after the client has died" do
    ada_client = client()
    assert :ok = Sessions.open("lab", "ses", "ada", ada_client, attrs("/tmp"))
    assert :ok = Sessions.open("lab", "ses", "bea", self(), attrs("/tmp"))
    ada = subscription("ada", "ses")
    ref = Process.monitor(ada)

    Process.exit(ada_client, :kill)

    assert_receive {:DOWN, ^ref, :process, ^ada, :normal}
    assert :ok = Sessions.leave("lab", "ses", "ada")
    assert :ok = Sessions.broadcast("lab", "ses", user("later"))
    assert notified("bea", "ses") == [message("ses", user("later"))]
    assert Process.alive?(session("ses"))
  end

  test "list filters on cwd and sorts newest first" do
    assert :ok =
             Sessions.open(
               "lab",
               "older",
               "a",
               self(),
               attrs("/work", clock: fn -> "2026-11-02T00:00:01Z" end)
             )

    assert :ok =
             Sessions.open(
               "lab",
               "newer",
               "b",
               self(),
               attrs("/work", clock: fn -> "2026-11-02T00:00:02Z" end)
             )

    assert :ok = Sessions.open("lab", "blank", "c", self(), attrs("/work"))

    assert :ok =
             Sessions.open(
               "lab",
               "other",
               "d",
               self(),
               attrs("/other", clock: fn -> "2026-11-02T00:00:03Z" end)
             )

    assert :ok =
             Sessions.open(
               "away",
               "newer",
               "e",
               self(),
               attrs("/work", clock: fn -> "2026-11-02T00:00:09Z" end)
             )

    assert :ok = Sessions.broadcast("lab", "older", user("old"))
    assert :ok = Sessions.broadcast("lab", "newer", user("new"))
    assert :ok = Sessions.broadcast("lab", "other", user("elsewhere"))
    assert :ok = Sessions.broadcast("away", "newer", user("away"))

    assert Sessions.list("lab", cwd: "/work") == %{
             sessions: [
               row("newer", "/work", "new", "2026-11-02T00:00:02Z"),
               row("older", "/work", "old", "2026-11-02T00:00:01Z"),
               row("blank", "/work", nil, nil)
             ],
             next_cursor: nil
           }

    assert Sessions.list("lab", cwd: "/other") == %{
             sessions: [row("other", "/other", "elsewhere", "2026-11-02T00:00:03Z")],
             next_cursor: nil
           }

    assert Sessions.list("away") == %{
             sessions: [row("newer", "/work", "away", "2026-11-02T00:00:09Z")],
             next_cursor: nil
           }

    assert Sessions.list("missing") == %{sessions: [], next_cursor: nil}
  end

  test "equal updatedAt sorts by sessionId" do
    stamp = fn -> "2026-11-02T00:00:04Z" end
    assert :ok = Sessions.open("lab", "m", "m", self(), attrs("/tmp", clock: stamp))
    assert :ok = Sessions.open("lab", "a", "a", self(), attrs("/tmp", clock: stamp))
    assert :ok = Sessions.broadcast("lab", "m", user("m"))
    assert :ok = Sessions.broadcast("lab", "a", user("a"))

    assert Enum.map(Sessions.list("lab").sessions, & &1["sessionId"]) == ["a", "m"]
  end

  test "list pages with an opaque cursor" do
    for n <- 1..@past_one_page do
      id = Integer.to_string(n)

      assert :ok =
               Sessions.open(
                 "lab",
                 id,
                 "c" <> id,
                 self(),
                 attrs("/work", clock: fn -> stamp(n) end)
               )

      assert :ok = Sessions.broadcast("lab", id, user(id))
    end

    assert :ok =
             Sessions.open(
               "lab",
               "side",
               "side",
               self(),
               attrs("/other", clock: fn -> stamp(100) end)
             )

    assert :ok = Sessions.broadcast("lab", "side", user("side"))

    assert :ok =
             Sessions.open(
               "away",
               "9",
               "away",
               self(),
               attrs("/work", clock: fn -> stamp(100) end)
             )

    assert :ok = Sessions.broadcast("away", "9", user("away"))

    %{sessions: first, next_cursor: cursor} = Sessions.list("lab", cwd: "/work")
    assert length(first) == 50
    assert is_binary(cursor)
    assert hd(first)["sessionId"] == "51"
    assert List.last(first)["sessionId"] == "2"
    refute Enum.any?(first, &(&1["sessionId"] == "side"))

    page = Sessions.list("lab", cwd: "/work", cursor: cursor)
    assert Sessions.list("lab", cwd: "/work", cursor: cursor) == page
    assert page == %{sessions: [row("1", "/work", "1", stamp(1))], next_cursor: nil}

    assert {:error, :invalid_cursor} = Sessions.list("lab", cursor: "nope")
    assert {:error, :invalid_cursor} = Sessions.list("away", cwd: "/work", cursor: cursor)
  end

  test "an unknown session" do
    assert {:error, :unknown} = Sessions.load("lab", "missing", "ada", self())
    assert {:error, :unknown} = Sessions.resume("lab", "missing", "ada", self())
    assert :ok = Sessions.broadcast("lab", "missing", user("x"))
    assert :ok = Sessions.leave("lab", "missing", "ada")
    assert :ok = Sessions.disconnect("ada")
    assert Sessions.list("lab") == %{sessions: [], next_cursor: nil}
  end

  test "a bad open or list option raises and the directory stays up" do
    assert_raise ArgumentError, ~r/:max_turns/, fn ->
      Sessions.open("lab", "ses", "ada", self(), %{cwd: "/tmp", history: [max_turns: 0]})
    end

    assert_raise KeyError, fn ->
      Sessions.open("lab", "ses", "ada", self(), %{})
    end

    assert_raise ArgumentError, ~r/:cwd/, fn ->
      Sessions.open("lab", "ses", "ada", self(), %{cwd: 1})
    end

    assert_raise ArgumentError, ~r/:history/, fn ->
      Sessions.open("lab", "ses", "ada", self(), %{cwd: "/tmp", history: %{}})
    end

    assert_raise ArgumentError, ~r/:cwd/, fn -> Sessions.list("lab", cwd: 1) end
    assert_raise ArgumentError, ~r/:cursor/, fn -> Sessions.list("lab", cursor: 1) end

    assert Sessions.list("lab") == %{sessions: [], next_cursor: nil}
    assert :ok = Sessions.open("lab", "ses", "ada", self(), attrs("/tmp"))
  end

  defp attrs(cwd, history \\ []) do
    %{cwd: cwd, history: Keyword.merge([clock: fn -> "2026-11-02T00:00:00Z" end], history)}
  end

  defp subscription(client_id, session_id, runtime \\ "lab") do
    :sys.get_state(Sessions).clients[client_id][{runtime, session_id}]
  end

  defp notified(client_id, session_id, runtime \\ "lab") do
    FakeSubscribe.notified(subscription(client_id, session_id, runtime))
  end

  defp session(session_id, runtime \\ "lab") do
    :sys.get_state(Sessions).sessions[{runtime, session_id}]
  end

  defp subscriptions(session_id, runtime \\ "lab") do
    :sys.get_state(session(session_id, runtime)).subscriptions
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

  defp row(session_id, cwd, title, updated_at) do
    %{"sessionId" => session_id, "cwd" => cwd, "title" => title, "updatedAt" => updated_at}
  end

  defp message(session_id, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => session_id, "update" => update}
    }
  end

  defp user(text) do
    %{"sessionUpdate" => "user_message_chunk", "content" => %{"type" => "text", "text" => text}}
  end

  defp note(dropped_turns, kept_turns, dropped_bytes) do
    %{
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
    }
  end

  defp bytes(update), do: byte_size(Frame.encode(update))

  defp stamp(n), do: DateTime.from_unix!(1_700_000_000 + n) |> DateTime.to_iso8601()
end
