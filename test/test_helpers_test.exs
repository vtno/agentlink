defmodule AgentLink.TestHelpersTest do
  use ExUnit.Case, async: true

  test "bounded waits retain state and fail on a pending step" do
    step = fn state -> if state == 0, do: {:continue, 1}, else: {:pending, state} end

    assert_raise ExUnit.AssertionError, ~r/timed out with 1/, fn ->
      AgentLink.TestHelpers.bounded_wait!(0, 0, step, fn state -> "timed out with #{state}" end)
    end
  end

  test "wrappers fail when the child exits before reporting readiness" do
    for {fixture, message} <- [
          {&AgentLink.TestHelpers.hold_fixture!("-", false, &1), "hold fixture child exited"},
          {&AgentLink.TestHelpers.setsid_fixture!/1, "setsid fixture child exited"}
        ] do
      {command, args} = fixture.(System.find_executable("false"))

      port =
        Port.open({:spawn_executable, command}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        await_ready!(port)
      end
    end
  end

  defp await_ready!(port) do
    step = fn output ->
      receive do
        {^port, {:data, data}} ->
          {:continue, output <> data}

        {^port, {:exit_status, status}} ->
          flunk("fixture exited #{status} before readiness: #{output}")
      after
        0 -> {:pending, output}
      end
    end

    AgentLink.TestHelpers.bounded_wait!("", 5_000, step, fn output ->
      "fixture did not report readiness before the deadline: #{output}"
    end)
  end
end
