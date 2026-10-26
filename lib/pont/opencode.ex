defmodule Pont.OpenCode do
  @moduledoc """
  Production behaviour. Runs `opencode acp` and leaves stderr off the ACP stream.
  """

  @behaviour Pont.Agent

  @doc "Start the agent. Must be called from the owner, because the port's stdout arrives at the caller."
  @impl true
  def open(owner, cwd) do
    ensure_owner(owner)
    {:ok, open_port(cwd)}
  end

  @impl true
  def write(port, data) do
    if is_port(port) and Port.info(port) do
      Port.command(port, data)
      :ok
    else
      :closed
    end
  end

  @impl true
  def close(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  end

  @doc "The executable this behaviour runs, with a relative symlink resolved."
  def bin do
    configured = Pont.Paths.opencode_bin()

    case File.read_link(configured) do
      {:ok, relative} ->
        configured |> Path.dirname() |> Path.join(relative) |> Path.expand()

      _ ->
        configured
    end
  end

  # Port.open delivers the port's stdout to the caller, so the caller must be the owner.
  defp ensure_owner(owner) do
    if owner == self() do
      :ok
    else
      raise "Pont.OpenCode.open/2 must be called from the owner (#{inspect(owner)})"
    end
  end

  defp open_port(cwd) do
    Port.open({:spawn_executable, bin()}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, ["acp"]},
      {:cd, cwd},
      {:env, port_env()}
    ])
  end

  defp port_env do
    System.get_env()
    |> Map.put("OPENCODE_DISABLE_AUTOUPDATE", "1")
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end
end
