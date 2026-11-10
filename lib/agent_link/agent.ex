defmodule AgentLink.Agent do
  @moduledoc """
  ACP stdio for one agent. The agent relay opens the agent through this behaviour.
  `AgentLink.Agent.Process` is the production behaviour. It runs the command from
  `AgentLink.Agent.Launch`. Tests that do not need a process supply a fake.
  `test/agent_process_test.exs`, `test/lifecycle_test.exs`, and
  `test/release_lifecycle_test.exs` start a fixture.
  """

  @doc "Start the agent. Stdout arrives at the owner as `{ref, {:data, binary}}`."
  @callback open(owner :: pid, launch :: AgentLink.Agent.Launch.t(), cwd :: String.t()) ::
              {:ok, term} | {:error, term}

  @doc "Write one chunk to the agent's stdin. `:closed` when the agent is gone."
  @callback write(term, iodata) :: :ok | :closed

  @doc "Stop the agent if it is still running. `:ok` when it is gone. `{:error, reason}` when the stop fails."
  @callback close(term) :: :ok | {:error, term}
end
