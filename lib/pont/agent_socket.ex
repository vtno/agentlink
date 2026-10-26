defmodule Pont.AgentSocket do
  @moduledoc """
  The plane's agent socket. The first frame is `pont.uplink` and lands in the registry.
  Later frames are ACP from that runtime. A hello from the same relay stops this
  socket so the new one can take the name. A hello from another relay, while this
  name is live, closes that new socket and leaves this one up. A hello whose
  instance id is too long closes that new socket and leaves any holder up.
  Permanent rejections use `Pont.SocketProtocol` close codes. Once registered, the socket
  routes ACP under the normalized name returned by the registry.
  """

  @behaviour WebSock
  require Logger

  defstruct name: nil, subject: nil

  @doc "Wait for the uplink hello. The subject is whoever the router authenticated."
  @impl true
  def init(%Pont.Access.Subject{} = subject), do: {:ok, %__MODULE__{subject: subject}}

  @doc """
  The first text frame must be pont.uplink. That claims the runtime name.
  Later frames are ACP from that runtime.
  """
  @impl true
  def handle_in({text, [opcode: :text]}, %__MODULE__{name: nil} = state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"method" => "pont.uplink", "params" => params}} when is_map(params) ->
        uplink = %Pont.Registry.Uplink{
          name: params["name"],
          label: params["label"],
          program: params["program"] || "opencode",
          instance: params["instance"]
        }

        case Pont.Registry.register(self(), uplink, state.subject) do
          {:ok, name} ->
            {:ok, %{state | name: name}}

          {:error, rejection} ->
            name = if is_binary(uplink.name), do: String.trim(uplink.name)

            close =
              {Pont.SocketProtocol.close_code(rejection),
               Pont.SocketProtocol.reason(rejection, name)}

            {:stop, :normal, close, state}
        end

      _ ->
        {:stop, :expected_uplink, state}
    end
  end

  def handle_in({text, [opcode: :text]}, %__MODULE__{name: name} = state) when is_binary(text) do
    Pont.Plane.agent_frame(name, text)
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(:superseded, state) do
    Logger.info("agent socket superseded name=#{state.name} the same relay dialed again")
    {:stop, :normal, state}
  end

  def handle_info({:send, json}, state) when is_binary(json) do
    {:push, [{:text, json}], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("agent socket closed name=#{inspect(state.name)} #{inspect(reason)}")
    :ok
  end
end
