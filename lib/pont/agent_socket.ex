defmodule Pont.AgentSocket do
  @moduledoc """
  One sidecar uplink. The first frame is `pont.uplink` and lands in the registry.
  Later frames are ACP from that runtime.
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
        case Pont.Registry.register(self(), params["name"], params["label"], params["program"] || "opencode", state.subject) do
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

  def handle_info(:replaced, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("agent uplink closed name=#{inspect(state.name)} #{inspect(reason)}")
    :ok
  end
end
