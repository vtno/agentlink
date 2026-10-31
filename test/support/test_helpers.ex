defmodule AgentLink.TestHelpers do
  @moduledoc "Shared test helpers."

  import ExUnit.Assertions

  def capture_info(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: level)
    end
  end

  def await_pid(name, attempts \\ 100) do
    case AgentLink.Registry.pid(name) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(20)
        await_pid(name, attempts - 1)

      nil ->
        flunk("uplink #{name} did not register")
    end
  end

  def restore(key, nil), do: Application.delete_env(:agent_link, key)
  def restore(key, value), do: Application.put_env(:agent_link, key, value)
end
