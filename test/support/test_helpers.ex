defmodule AgentLink.TestHelpers do
  @moduledoc "Shared test helpers."

  def await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end

  def kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    await_down(ref, pid)
  end

  def await(fun) do
    case fun.() do
      false -> await(fun)
      nil -> await(fun)
      result -> result
    end
  end

  def capture_info(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: level)
    end
  end

  def await_pid(name), do: await(fn -> AgentLink.Registry.pid(name) end)

  def restore(key, nil), do: Application.delete_env(:agent_link, key)
  def restore(key, value), do: Application.put_env(:agent_link, key, value)
end
