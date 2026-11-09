defmodule AgentLink.OwnedStop do
  @moduledoc """
  Stops a Linux process tree that a test captured.

  `capture/1` reads `/proc/<pid>/stat` while that pid is alive. Field 22 is
  `starttime`. The record is that pid and that `starttime`, plus the same
  pair for each process whose parent chain reached it during that read.
  `stop/1` sends `SIGKILL` only when the same pid still has that
  `starttime`. A reused pid has a different `starttime` and is left alone.
  `stop/1` also signals a process that was not in the record when its
  parent chain, in the same read, still reaches a recorded process that is
  still that process. A process that starts after the read is not signaled.

  `confirm_gone/3` repeats the check a fixed number of times. The success
  condition is that the recorded process is gone, is a zombie, or no longer
  has that `starttime`. When the bound is reached, it raises and names the
  pid and the recorded `starttime`.

  These functions read `/proc`. They were run on Linux. They are not a
  process-tree stop on macOS or Windows. When `/proc` cannot be read,
  `capture/1` returns `:error` and `stop/1` returns
  `{:error, :proc_unreadable}` without signaling.
  """

  # proc(5) counts pid as field 1 and comm as field 2. starttime is field 22.
  @starttime_field 19
  @confirm_attempts 10_000

  def capture(pid) when is_integer(pid) and pid > 1 do
    with {:ok, entries} <- snapshot(),
         %{starttime: starttime} <- Map.get(entries, pid) do
      {:ok, [%{pid: pid, starttime: starttime} | descendant_identities(pid, entries)]}
    else
      _ -> :error
    end
  end

  def capture(_pid), do: :error

  def stop(captured) when is_list(captured) do
    case snapshot() do
      :error ->
        {:error, :proc_unreadable}

      {:ok, entries} ->
        targets = select(captured, entries)
        Enum.each(targets, &sigkill_if_same/1)
        confirm_gone(targets, @confirm_attempts, &same_process?/1)
        targets
    end
  end

  def select(captured, entries) when is_list(captured) and is_map(entries) do
    matching =
      Enum.flat_map(captured, fn
        %{pid: pid, starttime: starttime} when is_integer(pid) and pid > 1 ->
          case Map.get(entries, pid) do
            %{starttime: ^starttime, state: state} when state != "Z" ->
              [%{pid: pid, starttime: starttime}]

            _ ->
              []
          end

        _ ->
          []
      end)

    seeds = Map.new(matching, fn %{pid: pid, starttime: starttime} -> {pid, starttime} end)

    extra =
      Enum.flat_map(entries, fn {pid, entry} ->
        if pid > 1 and entry.state != "Z" and not Map.has_key?(seeds, pid) and
             descendant_of_seed?(pid, entries, seeds, MapSet.new()) do
          [%{pid: pid, starttime: entry.starttime}]
        else
          []
        end
      end)

    Enum.uniq_by(matching ++ extra, fn %{pid: pid, starttime: starttime} -> {pid, starttime} end)
  end

  def descendants(root) when is_integer(root) and root > 1 do
    case snapshot() do
      {:ok, entries} ->
        entries
        |> Map.keys()
        |> Enum.filter(&descendant_of_pid?(&1, root, entries, MapSet.new()))

      :error ->
        []
    end
  end

  def descendants(_root), do: []

  def parse_stat(stat) when is_binary(stat) do
    with {pid, " (" <> _} <- Integer.parse(stat),
         matches when matches != [] <- :binary.matches(stat, ") "),
         {pos, _} = List.last(matches),
         rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2),
         fields = String.split(rest, " ", trim: true),
         true <- length(fields) > @starttime_field,
         [state, parent | _] <- fields,
         {ppid, ""} <- Integer.parse(parent),
         {starttime, ""} <- Integer.parse(Enum.at(fields, @starttime_field)) do
      {:ok, %{pid: pid, ppid: ppid, state: state, starttime: starttime}}
    else
      _ -> :error
    end
  end

  def confirm_gone(targets, attempts, still_same?)
      when is_list(targets) and is_integer(attempts) and attempts >= 0 and
             is_function(still_same?, 1) do
    confirm_gone(targets, attempts, still_same?, targets)
  end

  defp confirm_gone(_targets, _attempts, _still_same?, []), do: :ok

  defp confirm_gone(_targets, 0, _still_same?, left) do
    raise "OwnedStop could not confirm SIGKILL: " <>
            Enum.map_join(left, ", ", &describe/1)
  end

  defp confirm_gone(targets, attempts, still_same?, left) do
    receive do
    after
      0 ->
        confirm_gone(targets, attempts - 1, still_same?, Enum.filter(left, still_same?))
    end
  end

  defp snapshot do
    case File.ls("/proc") do
      {:ok, names} ->
        {:ok, Enum.reduce(names, %{}, &put_entry/2)}

      _ ->
        :error
    end
  end

  defp put_entry(name, acc) do
    case Integer.parse(name) do
      {pid, ""} ->
        case File.read("/proc/#{pid}/stat") do
          {:ok, stat} ->
            case parse_stat(stat) do
              {:ok, entry} -> Map.put(acc, pid, entry)
              :error -> acc
            end

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp descendant_identities(root, entries, seen \\ MapSet.new()) do
    kids =
      Enum.filter(entries, fn {pid, entry} ->
        entry.ppid == root and pid > 1 and not MapSet.member?(seen, pid)
      end)

    seen = Enum.reduce(kids, seen, fn {pid, _entry}, acc -> MapSet.put(acc, pid) end)

    Enum.flat_map(kids, fn {pid, entry} ->
      [%{pid: pid, starttime: entry.starttime} | descendant_identities(pid, entries, seen)]
    end)
  end

  defp descendant_of_seed?(pid, entries, seeds, seen) do
    cond do
      MapSet.member?(seen, pid) ->
        false

      seed_match?(pid, entries, seeds) ->
        true

      true ->
        case Map.get(entries, pid) do
          %{ppid: ppid} when is_integer(ppid) and ppid > 1 ->
            descendant_of_seed?(ppid, entries, seeds, MapSet.put(seen, pid))

          _ ->
            false
        end
    end
  end

  defp seed_match?(pid, entries, seeds) do
    case {Map.get(seeds, pid), Map.get(entries, pid)} do
      {starttime, %{starttime: starttime}} when is_integer(starttime) -> true
      _ -> false
    end
  end

  defp descendant_of_pid?(pid, root, entries, seen) do
    cond do
      pid == root or MapSet.member?(seen, pid) ->
        false

      true ->
        case Map.get(entries, pid) do
          %{ppid: ^root} ->
            true

          %{ppid: ppid} when is_integer(ppid) and ppid > 1 ->
            descendant_of_pid?(ppid, root, entries, MapSet.put(seen, pid))

          _ ->
            false
        end
    end
  end

  defp same_process?(%{pid: pid, starttime: starttime}) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case parse_stat(stat) do
          {:ok, %{starttime: ^starttime, state: state}} -> state != "Z"
          _ -> false
        end

      _ ->
        false
    end
  end

  defp describe(%{pid: pid, starttime: starttime}) do
    now =
      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} ->
          case parse_stat(stat) do
            {:ok, %{state: state, starttime: current}} ->
              "state=#{state} starttime=#{current}"

            :error ->
              "unreadable"
          end

        _ ->
          "gone"
      end

    "pid=#{pid} recorded_starttime=#{starttime} #{now}"
  end

  defp sigkill_if_same(%{pid: pid, starttime: starttime}) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case parse_stat(stat) do
          {:ok, %{starttime: ^starttime, state: state}} when state != "Z" ->
            sigkill(pid)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp sigkill(pid) do
    case System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if output =~ "No such process" do
          :ok
        else
          raise "OwnedStop kill pid=#{pid} status=#{status} output=#{output}"
        end
    end
  end
end
