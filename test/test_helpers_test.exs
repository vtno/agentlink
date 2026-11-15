defmodule AgentLink.TestHelpersTest do
  use ExUnit.Case, async: true

  test "wrappers fail when the child exits before reporting readiness" do
    for {fixture, executable_index, message} <- [
          {&AgentLink.TestHelpers.hold_fixture!/0, 6, "hold fixture child exited"},
          {&AgentLink.TestHelpers.setsid_fixture!/0, 5, "setsid fixture child exited"}
        ] do
      {command, args} = fixture.()
      args = List.replace_at(args, executable_index, System.find_executable("false"))

      port =
        Port.open({:spawn_executable, command}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        await_ready!(port, "", System.monotonic_time(:millisecond) + 5_000)
      end
    end
  end

  defp await_ready!(port, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        await_ready!(port, output <> data, deadline)

      {^port, {:exit_status, status}} ->
        flunk("fixture exited #{status} before readiness: #{output}")
    after
      0 ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("fixture did not report readiness before the deadline: #{output}")
        else
          await_ready!(port, output, deadline)
        end
    end
  end
end
