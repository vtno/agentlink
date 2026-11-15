defmodule AgentLink.ClientSocket do
  @moduledoc """
  The app connection. Registers with the plane, then forwards each text frame.

  The socket sends a WebSocket ping on a timer. A missed pong closes it.
  `AgentLink.Keepalive` owns that timer. The router passes the subject only,
  so a listening plane reads the environment variable, then the application
  env, then the defaults.
  """

  @behaviour WebSock

  defstruct [:id, keepalive: nil]

  @doc """
  Join the plane and keep the id this socket was given.

  `{subject, opts}` sets the keepalive. `:ping_interval` and `:pong_timeout`
  are milliseconds. `:scheduler` defaults to `Process`. The router passes the
  subject only. See `AgentLink.Keepalive`.
  """
  @impl true
  def init(%AgentLink.Access.Subject{} = subject), do: init({subject, []})

  def init({%AgentLink.Access.Subject{} = subject, opts}) when is_list(opts) do
    id = AgentLink.Plane.register(self(), subject)
    keepalive = opts |> AgentLink.Keepalive.new() |> AgentLink.Keepalive.arm(self())
    {:ok, %__MODULE__{id: id, keepalive: keepalive}}
  end

  @doc "One text frame from the client. Hand it to the plane as a client frame."
  @impl true
  def handle_in({text, [opcode: :text]}, %__MODULE__{} = state) when is_binary(text) do
    AgentLink.Plane.client_frame(state.id, text)
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @doc """
  A pong clears the keepalive deadline. A ping does not. The server has
  already answered that ping.
  """
  @impl true
  def handle_control(frame, %__MODULE__{} = state) do
    {:ok, keepalive} = AgentLink.Keepalive.handle_control(frame, state.keepalive)
    {:ok, %{state | keepalive: keepalive}}
  end

  @doc "The plane has a JSON message for this client."
  @impl true
  def handle_info({:send, json}, state) when is_binary(json) do
    {:push, [{:text, json}], state}
  end

  def handle_info(message, %__MODULE__{} = state) do
    case AgentLink.Keepalive.handle_info(message, state.keepalive, self()) do
      {:push, frames, keepalive} ->
        {:push, frames, %{state | keepalive: keepalive}}

      {:stop, reason, close, keepalive} ->
        {:stop, reason, close, %{state | keepalive: keepalive}}

      :ignore ->
        {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
