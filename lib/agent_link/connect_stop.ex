defmodule AgentLink.ConnectStop do
  @moduledoc """
  `SIGTERM` handling for `agentlink connect`.

  See [Release stop](../../docs/agent.md#release-stop).
  """

  @behaviour :gen_event

  @impl true
  def init(_args) do
    {:ok, []}
  end

  @impl true
  def handle_event(:sigusr1, _state) do
    :erlang.halt(~c"Received SIGUSR1")
  end

  def handle_event(:sigquit, _state) do
    :erlang.halt()
  end

  def handle_event(:sigterm, state) do
    :error_logger.info_msg(~c"SIGTERM received - shutting down~n")
    :init.stop(1)
    {:ok, state}
  end

  def handle_event(_event, state) do
    {:ok, state}
  end

  @impl true
  def handle_call(_request, state) do
    {:ok, :ok, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  def code_change(_old, state, _extra) do
    {:ok, state}
  end
end
