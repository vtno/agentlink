defmodule AgentLink.Stdio.Console do
  @moduledoc """
  Production behaviour. Opens file descriptors 0 and 1.

  `open/1` runs in the owner. The owner receives `{port, {:data, binary}}`
  and `{port, :eof}` when stdin ends.
  """

  @behaviour AgentLink.Stdio

  @doc """
  Open file descriptors 0 and 1.

  The caller must be `owner`. Another caller gets `{:error, message}` and
  no port is opened.
  """
  @impl true
  def open(owner) when is_pid(owner) do
    if owner == self() do
      {:ok, Port.open({:fd, 0, 1}, [:binary, :eof])}
    else
      {:error, "AgentLink.Stdio.Console.open/1 must be called from the owner"}
    end
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
end
