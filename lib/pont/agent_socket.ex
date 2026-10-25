defmodule Pont.AgentSocket do
  @moduledoc """
  The plane's agent socket. The first frame is `pont.uplink` and lands in the registry.
  Later frames are ACP from that runtime. A later hello with the same name closes this socket.
  """

  @behaviour WebSock
  require Logger

  # Private-use WebSocket close (RFC 6455, 4000-4999). The relay treats this
  # code as "another uplink took my name" and does not redial.
  @duplicate_close_code 4001

  defstruct name: nil, subject: nil

  @doc "Close code for an uplink whose name was taken by a later hello."
  def duplicate_close_code, do: @duplicate_close_code

  @doc "Close reason naming the link that was claimed twice."
  def duplicate_reason(name) when is_binary(name), do: ~s(another uplink registered as "#{name}")
  def duplicate_reason(_name), do: "another uplink registered with the same name"

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
          program: params["program"] || "opencode"
        }

        case Pont.Registry.register(self(), uplink, state.subject) do
          :ok -> {:ok, %{state | name: params["name"]}}
          {:error, reason} -> {:stop, reason, state}
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
  def handle_info({:send, json}, state) when is_binary(json) do
    {:push, [{:text, json}], state}
  end

  def handle_info(:replaced, %__MODULE__{name: name} = state) do
    reason = duplicate_reason(name)
    Logger.warning("uplink replaced name=#{name} another uplink registered with the same name")
    {:stop, :normal, {@duplicate_close_code, reason}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("agent socket closed name=#{inspect(state.name)} #{inspect(reason)}")
    :ok
  end
end
