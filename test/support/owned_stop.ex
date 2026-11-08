defmodule AgentLink.OwnedStop do
  @moduledoc """
  Stops the OS process behind a test port, and the processes that process
  started.

  A Burrito launcher exits on `SIGTERM` and leaves its VM running. The
  launcher is also the VM's stdout pipe, so a later `SIGTERM` to that VM
  does not finish. `stop_port/1` sends `SIGKILL` to the launcher pid and to
  every process whose parent chain starts at that pid.

  The parent chain comes from `/proc` on Linux. macOS and Windows were not run.
  """

  def stop_port(port) when is_port(port) do
    pids =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          owned = [pid | descendants(pid)]
          Enum.each(owned, &sigkill/1)
          owned

        _ ->
          []
      end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    await_gone(pids)
    pids
  end

  def descendants(root) when is_integer(root) do
    descendants(root, ppid_map(), MapSet.new())
  end

  defp descendants(root, map, seen) do
    kids =
      map
      |> Enum.filter(fn {pid, ppid} -> ppid == root and not MapSet.member?(seen, pid) end)
      |> Enum.map(fn {pid, _ppid} -> pid end)

    seen = Enum.reduce(kids, seen, &MapSet.put(&2, &1))
    kids ++ Enum.flat_map(kids, &descendants(&1, map, seen))
  end

  defp ppid_map do
    case File.ls("/proc") do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          case Integer.parse(name) do
            {pid, ""} ->
              case ppid(pid) do
                nil -> []
                parent -> [{pid, parent}]
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp ppid(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> ppid_from_stat(stat)
      _ -> nil
    end
  end

  defp ppid_from_stat(stat) do
    case :binary.matches(stat, ") ") do
      [] ->
        nil

      matches ->
        {pos, _} = List.last(matches)
        rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)

        case String.split(rest, " ", parts: 3) do
          [_state, parent | _] ->
            case Integer.parse(parent) do
              {n, ""} -> n
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case :binary.matches(stat, ") ") do
          [] ->
            true

          matches ->
            {pos, _} = List.last(matches)
            rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
            not String.starts_with?(rest, "Z ")
        end

      _ ->
        false
    end
  end

  defp await_gone(pids) do
    receive do
    after
      0 ->
        left = Enum.filter(pids, &running?/1)
        if left == [], do: :ok, else: await_gone(left)
    end
  end

  defp sigkill(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
