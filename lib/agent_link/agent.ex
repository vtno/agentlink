defmodule AgentLink.Agent do
  @moduledoc """
  ACP stdio for one agent. The agent relay opens the agent through this behaviour.
  `AgentLink.Agent.Process` is the production behaviour. It runs the command from
  `AgentLink.Agent.Launch`. Tests supply a fake so the suite never starts that command.
  """

  @doc "Start the agent. Stdout arrives at the owner as `{ref, {:data, binary}}`."
  @callback open(owner :: pid, launch :: AgentLink.Agent.Launch.t(), cwd :: String.t()) ::
              {:ok, term} | {:error, term}

  @doc "Write one chunk to the agent's stdin. `:closed` when the agent is gone."
  @callback write(term, iodata) :: :ok | :closed

  @doc "Stop the agent if it is still running."
  @callback close(term) :: :ok
end
