defmodule AgentLink.ConnectStop do
  @moduledoc """
  `SIGTERM` handling for `agentlink connect`.

  `:erl_signal_handler` calls `:init.stop/0`, and that halt uses status 0.
  This handler logs the same notice and calls `:init.stop/1`, so the status
  is 1 in the process that is already stopping. The connect watcher leaves
  that halt alone once `:init.get_status/0` is `:stopping`. `SIGINT` opens
  the Erlang BREAK prompt in this mode, the same as a plain release. The
  catch-all does not stop that prompt.
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
