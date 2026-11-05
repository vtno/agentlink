defmodule AgentLink.Plane.History do
  @moduledoc """
  The capped replay of one session. The history is one struct. The module
  starts no process. The session process calls `append/2` when the plane
  broadcasts a live update.

  `append/2` stores one inner `session/update` object. A `user_message_chunk`
  starts a turn. Updates that arrive before the first `user_message_chunk` are
  one turn. Any other update stays in the current turn. A turn is never split.

  The byte size of an update is the size of `AgentLink.Frame.encode/1`.
  `:max_turns` defaults to 50 and `:max_bytes` defaults to 1_000_000. Each
  value must be an integer of at least 1. The buffer keeps the newest whole
  turns that fit both limits. When the newest turn alone is larger than
  `:max_bytes`, that turn stays.

  `replay/1` returns the kept updates, oldest first. An empty history returns
  an empty list. When a turn has been dropped, or the kept turns are larger
  than `:max_bytes`, the first update is a note. `replay/1` builds that note.
  Neither cap counts the note. The note is an `agent_message_chunk` with the
  text "Earlier turns were omitted." The `_meta` map is:

      %{
        "agentlink" => %{
          "history" => "truncated",
          "droppedTurns" => dropped_turns,
          "keptTurns" => kept_turns,
          "droppedBytes" => dropped_bytes
        }
      }

  `droppedTurns` counts turns that are not in the replay. `droppedBytes` is
  the total byte size of those turns, measured with `AgentLink.Frame.encode/1`.
  `keptTurns` counts the turns that are.

  `info/1` is the `session/list` row. The fields are `sessionId`, `cwd`,
  `title`, and `updatedAt`. A `session_info_update` with a binary `title` sets
  the title. A `nil` title clears it. Omitting `title` leaves the stored
  title. When no `session_info_update` title is set, the title comes from the
  first `user_message_chunk` text. `append/2` trims that text before it takes
  the first line, and then it trims the line. The first trim, the one on the
  whole text, removes a leading blank line. If nothing remains, the title is
  `nil`. Otherwise the line is cut to 100 characters. `updatedAt` is an RFC 3339 binary, or `nil` when
  nothing has set it. A `session_info_update` with a binary `updatedAt` sets it. A `nil`
  `updatedAt` clears it. Any other update sets it from `:clock`.
  `:clock` is a function of arity 0. It defaults to a function that returns
  `DateTime.to_iso8601/1` of `DateTime.utc_now/0`.
  """

  @default_max_turns 50
  @default_max_bytes 1_000_000
  @title_chars 100

  @type t :: %__MODULE__{}

  defstruct [
    :session_id,
    :cwd,
    :max_turns,
    :max_bytes,
    :clock,
    turns: [],
    dropped_turns: 0,
    dropped_bytes: 0,
    info_title: nil,
    user_title: nil,
    saw_user: false,
    updated_at: nil
  ]

  @doc """
  Start an empty history.

  `:session_id` and `:cwd` are required. `:max_turns` defaults to 50.
  `:max_bytes` defaults to 1_000_000. Both must be integers of at least 1.
  `:clock` is a function of arity 0 that returns an RFC 3339 binary. It
  defaults to `DateTime.to_iso8601/1` of `DateTime.utc_now/0`.
  """
  @spec new(keyword) :: t
  def new(opts) when is_list(opts) do
    session_id = binary!(opts, :session_id)
    cwd = binary!(opts, :cwd)

    %__MODULE__{
      session_id: session_id,
      cwd: cwd,
      max_turns: at_least_one(opts, :max_turns, @default_max_turns),
      max_bytes: at_least_one(opts, :max_bytes, @default_max_bytes),
      clock: clock(opts)
    }
  end

  @doc "Store one inner `session/update` object and return the history."
  @spec append(t, update :: map) :: t
  def append(%__MODULE__{} = history, update) when is_map(update) do
    history
    |> put_title_and_updated_at(update)
    |> put_update(update)
    |> cap()
  end

  @doc """
  The kept updates, oldest first.

  When the history was cut, the first map is the truncation note.
  """
  @spec replay(t) :: [map]
  def replay(%__MODULE__{} = history) do
    updates = Enum.flat_map(history.turns, &Enum.reverse(&1.updates))

    if cut?(history) do
      [note(history) | updates]
    else
      updates
    end
  end

  @doc "The `session/list` row for this session."
  @spec info(t) :: map
  def info(%__MODULE__{} = history) do
    %{
      "sessionId" => history.session_id,
      "cwd" => history.cwd,
      "title" => display_title(history),
      "updatedAt" => history.updated_at
    }
  end

  defp binary!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_binary(value) do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a binary, got: #{inspect(value)}"
    end
  end

  defp at_least_one(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= 1 do
      value
    else
      raise ArgumentError,
            "#{inspect(key)} must be an integer of at least 1, got: #{inspect(value)}"
    end
  end

  defp clock(opts) do
    clock = Keyword.get(opts, :clock, &utc_now/0)

    if is_function(clock, 0) do
      clock
    else
      raise ArgumentError, ":clock must be a function of arity 0, got: #{inspect(clock)}"
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp put_title_and_updated_at(history, %{"sessionUpdate" => "session_info_update"} = update) do
    history
    |> put_info_title(update)
    |> put_info_time(update)
  end

  defp put_title_and_updated_at(history, %{"sessionUpdate" => "user_message_chunk"} = update) do
    history = stamp(history)

    if history.saw_user do
      history
    else
      %{history | saw_user: true, user_title: clip_user(update)}
    end
  end

  defp put_title_and_updated_at(history, _update), do: stamp(history)

  defp put_info_title(history, %{"title" => title}) when is_binary(title) do
    %{history | info_title: title}
  end

  defp put_info_title(history, %{"title" => nil}) do
    %{history | info_title: nil}
  end

  defp put_info_title(history, _update), do: history

  defp put_info_time(history, %{"updatedAt" => at}) when is_binary(at) do
    %{history | updated_at: at}
  end

  defp put_info_time(history, %{"updatedAt" => nil}) do
    %{history | updated_at: nil}
  end

  defp put_info_time(history, _update), do: stamp(history)

  defp stamp(history) do
    case history.clock.() do
      at when is_binary(at) -> %{history | updated_at: at}
      other -> raise ArgumentError, ":clock must return a binary, got: #{inspect(other)}"
    end
  end

  defp clip_user(%{"content" => %{"type" => "text", "text" => text}}) when is_binary(text) do
    line =
      text
      |> String.trim()
      |> first_line()
      |> String.trim()

    case line do
      "" -> nil
      line -> String.slice(line, 0, @title_chars)
    end
  end

  defp clip_user(_update), do: nil

  defp first_line(text) do
    text
    |> String.split("\r\n", parts: 2)
    |> hd()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.split("\r", parts: 2)
    |> hd()
  end

  defp display_title(%{info_title: title}) when is_binary(title), do: title
  defp display_title(%{user_title: title}), do: title

  defp put_update(history, update) do
    bytes = encoded_bytes(update)

    turns =
      if user_message?(update) or history.turns == [] do
        history.turns ++ [%{updates: [update], bytes: bytes}]
      else
        List.update_at(history.turns, -1, fn turn ->
          %{turn | updates: [update | turn.updates], bytes: turn.bytes + bytes}
        end)
      end

    %{history | turns: turns}
  end

  defp user_message?(%{"sessionUpdate" => "user_message_chunk"}), do: true
  defp user_message?(_update), do: false

  defp encoded_bytes(update), do: byte_size(AgentLink.Frame.encode(update))

  # Keep a suffix of the turn list. Once a turn does not fit, every older
  # turn drops with it. The newest turn stays whole even when it alone
  # exceeds max_bytes.
  defp cap(history) do
    {kept, dropped} = split(history.turns, history.max_turns, history.max_bytes)

    %{
      history
      | turns: kept,
        dropped_turns: history.dropped_turns + length(dropped),
        dropped_bytes: history.dropped_bytes + sum_bytes(dropped)
    }
  end

  defp split(turns, max_turns, max_bytes) do
    {kept, dropped, _count, _bytes, _done} =
      turns
      |> Enum.reverse()
      |> Enum.reduce({[], [], 0, 0, false}, fn turn, {kept, dropped, count, bytes, done} ->
        fits = count < max_turns and bytes + turn.bytes <= max_bytes

        if not done and (count == 0 or fits) do
          {[turn | kept], dropped, count + 1, bytes + turn.bytes, false}
        else
          {kept, [turn | dropped], count, bytes, true}
        end
      end)

    {kept, dropped}
  end

  defp sum_bytes(turns), do: Enum.reduce(turns, 0, &(&1.bytes + &2))

  defp cut?(%{dropped_turns: dropped}) when dropped > 0, do: true

  defp cut?(history), do: sum_bytes(history.turns) > history.max_bytes

  defp note(history) do
    %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "Earlier turns were omitted."},
      "_meta" => %{
        "agentlink" => %{
          "history" => "truncated",
          "droppedTurns" => history.dropped_turns,
          "keptTurns" => length(history.turns),
          "droppedBytes" => history.dropped_bytes
        }
      }
    }
  end
end
