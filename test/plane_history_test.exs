defmodule AgentLink.Plane.HistoryTest do
  use ExUnit.Case, async: true

  alias AgentLink.Plane.History

  test "an empty history replays nothing and has no note" do
    history = history(clock: fn -> raise "clock" end)

    assert History.replay(history) == []

    assert History.info(history) == %{
             "sessionId" => "ses",
             "cwd" => "/tmp",
             "title" => nil,
             "updatedAt" => nil
           }
  end

  test "a user_message_chunk starts a turn and earlier updates are one turn" do
    pre = agent("pre")
    also = agent("also")
    first = user("first")
    mid = agent("mid")
    second = user("second")

    open =
      history()
      |> History.append(pre)
      |> History.append(also)
      |> History.append(first)
      |> History.append(mid)
      |> History.append(second)

    assert History.replay(open) == [pre, also, first, mid, second]

    capped =
      history(max_turns: 2)
      |> History.append(pre)
      |> History.append(also)
      |> History.append(first)
      |> History.append(mid)
      |> History.append(second)

    assert History.replay(capped) == [
             truncation(1, 2, bytes(pre) + bytes(also)),
             first,
             mid,
             second
           ]
  end

  test "max_turns keeps the newest turns and remembers each dropped turn" do
    first = user("1")
    second = user("2")
    third = user("3")
    fourth = user("4")

    history =
      history(max_turns: 2)
      |> History.append(first)
      |> History.append(second)
      |> History.append(third)

    assert History.replay(history) == [
             truncation(1, 2, bytes(first)),
             second,
             third
           ]

    history = History.append(history, fourth)

    assert History.replay(history) == [
             truncation(2, 2, bytes(first) + bytes(second)),
             third,
             fourth
           ]
  end

  test "max_turns defaults to 50" do
    under =
      Enum.reduce(1..50, history(), fn n, history ->
        History.append(history, user(Integer.to_string(n)))
      end)

    assert History.replay(under) == Enum.map(1..50, &user(Integer.to_string(&1)))

    over = History.append(under, user("51"))
    [note | updates] = History.replay(over)

    assert note == truncation(1, 50, bytes(user("1")))
    assert updates == Enum.map(2..51, &user(Integer.to_string(&1)))
  end

  test "max_bytes defaults to 1_000_000" do
    n = 1_000_000 - bytes(user(""))
    full = user(String.duplicate("a", n))
    assert bytes(full) == 1_000_000

    history = history() |> History.append(full)
    assert History.replay(history) == [full]

    extra = user("b")
    history = History.append(history, extra)

    assert History.replay(history) == [truncation(1, 1, 1_000_000), extra]
  end

  test "max_bytes drops a whole older turn and keeps a suffix that fits" do
    first = user("one")
    mid = agent("two")
    last = user("three")
    turn_bytes = bytes(first) + bytes(mid)
    exact = turn_bytes + bytes(last)

    fitted =
      history(max_bytes: exact)
      |> History.append(first)
      |> History.append(mid)
      |> History.append(last)

    assert History.replay(fitted) == [first, mid, last]

    short = exact - 1

    split =
      history(max_bytes: short)
      |> History.append(first)
      |> History.append(mid)
      |> History.append(last)

    assert History.replay(split) == [truncation(1, 1, turn_bytes), last]

    small = user("a")
    wide = user(String.duplicate("m", 40))
    newest = user("z")
    hole = bytes(newest) + bytes(wide) - 1

    assert bytes(newest) + bytes(small) <= hole
    assert bytes(newest) + bytes(wide) > hole

    gapped =
      history(max_bytes: hole)
      |> History.append(small)
      |> History.append(wide)
      |> History.append(newest)

    assert History.replay(gapped) == [
             truncation(2, 1, bytes(small) + bytes(wide)),
             newest
           ]
  end

  test "the newest turn is kept when it alone exceeds max_bytes" do
    only = user("hello")
    history = history(max_bytes: 1) |> History.append(only)

    assert History.replay(history) == [truncation(0, 1, 0), only]

    older = user("old")
    newest = user("new")

    history =
      history(max_bytes: 1)
      |> History.append(older)
      |> History.append(newest)

    assert History.replay(history) == [truncation(1, 1, bytes(older)), newest]

    head = user("head")
    tail = agent("tail")

    history =
      history(max_bytes: 1)
      |> History.append(head)
      |> History.append(tail)

    assert History.replay(history) == [truncation(0, 1, 0), head, tail]
  end

  test "the title follows a session_info_update, otherwise the clipped first user chunk" do
    body = String.duplicate("a", 99) <> "é" <> "z"
    first = user("  " <> body <> "\nrest")
    assert String.length(body) == 101

    history = history() |> History.append(first) |> History.append(user("later"))

    assert History.info(history)["title"] == String.duplicate("a", 99) <> "é"

    long_title = String.duplicate("t", 150)
    named = %{"sessionUpdate" => "session_info_update", "title" => long_title}
    history = History.append(history, named)

    assert History.info(history)["title"] == long_title
    assert History.replay(history) == [first, user("later"), named]

    spaced = %{"sessionUpdate" => "session_info_update", "title" => "  Named  "}
    history = History.append(history, spaced)
    assert History.info(history)["title"] == "  Named  "

    history = History.append(history, %{"sessionUpdate" => "session_info_update", "title" => nil})

    assert History.info(history)["title"] == String.duplicate("a", 99) <> "é"

    cleared =
      history()
      |> History.append(%{"sessionUpdate" => "session_info_update", "title" => "Temp"})
      |> History.append(%{"sessionUpdate" => "session_info_update", "title" => nil})

    assert History.info(cleared)["title"] == nil

    image = %{
      "sessionUpdate" => "user_message_chunk",
      "content" => %{"type" => "image", "data" => "aa"}
    }

    assert History.info(history() |> History.append(image))["title"] == nil

    hello = user("hello")
    kept = %{"sessionUpdate" => "session_info_update", "title" => "Kept"}
    next = user("next")

    kept_title =
      history(max_turns: 1)
      |> History.append(hello)
      |> History.append(kept)
      |> History.append(next)

    assert History.info(kept_title)["title"] == "Kept"

    assert History.replay(kept_title) == [
             truncation(1, 1, bytes(hello) + bytes(kept)),
             next
           ]
  end

  test "updatedAt comes from :clock unless a session_info_update sets it" do
    history = history(clock: clock(["t1", "t2", "t3", "t4"]))
    assert History.info(history)["updatedAt"] == nil

    history = History.append(history, user("hello"))
    assert History.info(history)["updatedAt"] == "t1"
    assert History.info(history)["title"] == "hello"

    stop = %{
      "sessionUpdate" => "session_info_update",
      "_meta" => %{"stopReason" => "end_turn"}
    }

    history = History.append(history, stop)
    assert History.info(history)["updatedAt"] == "t2"
    assert History.info(history)["title"] == "hello"
    assert History.replay(history) == [user("hello"), stop]

    history =
      History.append(history, %{"sessionUpdate" => "session_info_update", "title" => "Named"})

    assert History.info(history)["updatedAt"] == "t3"
    assert History.info(history)["title"] == "Named"

    history =
      History.append(history, %{
        "sessionUpdate" => "session_info_update",
        "updatedAt" => "2020-01-01T00:00:00Z"
      })

    assert History.info(history)["updatedAt"] == "2020-01-01T00:00:00Z"
    assert History.info(history)["title"] == "Named"

    history =
      History.append(history, %{"sessionUpdate" => "session_info_update", "updatedAt" => nil})

    assert History.info(history)["updatedAt"] == nil
    assert History.info(history)["title"] == "Named"

    history = History.append(history, agent("done"))
    assert History.info(history)["updatedAt"] == "t4"
  end

  test "max_turns and max_bytes must be integers of at least 1" do
    assert_raise ArgumentError, ~r/:max_turns/, fn -> history(max_turns: 0) end
    assert_raise ArgumentError, ~r/:max_bytes/, fn -> history(max_bytes: 0) end
    assert_raise ArgumentError, ~r/:clock/, fn -> history(clock: :utc) end

    assert_raise ArgumentError, ~r/return a binary/, fn ->
      history(clock: fn -> :now end) |> History.append(user("a"))
    end

    assert_raise KeyError, fn -> History.new(cwd: "/tmp") end
    assert_raise KeyError, fn -> History.new(session_id: "ses") end
    assert_raise ArgumentError, ~r/:session_id/, fn -> history(session_id: nil) end
    assert_raise ArgumentError, ~r/:cwd/, fn -> history(cwd: 1) end
  end

  defp history(opts \\ []) do
    opts =
      Keyword.merge(
        [session_id: "ses", cwd: "/tmp", clock: fn -> "2026-11-01T00:00:00Z" end],
        opts
      )

    History.new(opts)
  end

  defp clock(values) do
    {:ok, pid} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(pid, fn [head | tail] -> {head, tail} end)
    end
  end

  defp user(text) do
    %{"sessionUpdate" => "user_message_chunk", "content" => %{"type" => "text", "text" => text}}
  end

  defp agent(text) do
    %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => text}}
  end

  defp bytes(update), do: byte_size(AgentLink.Frame.encode(update))

  defp truncation(dropped_turns, kept_turns, dropped_bytes) do
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
end
