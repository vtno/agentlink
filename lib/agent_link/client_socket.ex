defmodule AgentLink.ClientSocket do
  @moduledoc """
  The app connection. Registers with the plane, then forwards each text frame.
  """

  @behaviour WebSock

  defstruct [:id]

  @doc "Join the plane and keep the id this socket was given."
  @impl true
  def init(%AgentLink.Access.Subject{} = subject) do
    id = AgentLink.Plane.register(self(), subject)
    {:ok, %__MODULE__{id: id}}
  end

  @doc "One text frame from the client. Hand it to the plane as a client frame."
  @impl true
  def handle_in({text, [opcode: :text]}, %__MODULE__{} = state) when is_binary(text) do
    AgentLink.Plane.client_frame(state.id, text)
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @doc "The plane has a JSON message for this client."
  @impl true
  def handle_info({:send, json}, state) when is_binary(json) do
    {:push, [{:text, json}], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
