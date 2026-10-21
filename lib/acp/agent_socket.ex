defmodule Acp.AgentSocket do
  @moduledoc """
  One sidecar uplink. The first frame is `acp.uplink` and lands in the registry.
  Later frames are ACP from that runtime.
  """

  @behaviour WebSock
  require Logger

  defstruct name: nil

  @doc "Wait for the uplink hello before accepting ACP."
  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @doc """
  The first text frame must be acp.uplink. That claims the runtime name.
  Later frames are ACP from that runtime.
  """
  @impl true
  def handle_in({text, [opcode: :text]}, %__MODULE__{name: nil} = state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"method" => "acp.uplink", "params" => params}} when is_map(params) ->
        case Acp.Registry.register(self(), params["name"], params["label"]) do
          :ok -> {:ok, %{state | name: params["name"]}}
          {:error, reason} -> {:stop, reason, state}
        end

      _ ->
        {:stop, :expected_uplink, state}
    end
  end

  def handle_in({text, [opcode: :text]}, %__MODULE__{name: name} = state) when is_binary(text) do
    Acp.Plane.agent_frame(name, text)
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
