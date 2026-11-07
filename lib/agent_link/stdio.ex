defmodule AgentLink.Stdio do
  @moduledoc """
  Stdin and stdout for one editor. The client relay opens this behaviour.
  `AgentLink.Stdio.Console` is the production behaviour. It reads file
  descriptor 0 and writes file descriptor 1. Tests pass a fake.

  `open/1` runs in the owner. Chunks arrive there as `{term, {:data, binary}}`.
  """

  @doc """
  Open stdio.

  `owner` is the pid that receives `{term, {:data, binary}}`. The call runs
  in that process, because that is where the port delivers bytes.
  """
  @callback open(owner :: pid) :: {:ok, term} | {:error, term}

  @doc "Write one chunk. `:closed` when stdio is gone."
  @callback write(term, iodata) :: :ok | :closed

  @doc "Close stdio if it is still open. `:ok` when it is already closed."
  @callback close(term) :: :ok
end
