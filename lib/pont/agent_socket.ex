defmodule Pont.AgentSocket do
  @moduledoc """
  The plane's agent socket. The first frame is `pont.uplink` and lands in the registry.
  Later frames are ACP from that runtime. A hello from the same relay stops this
  socket so the new one can take the name. A hello from another relay, while this
  name is live, closes that new socket and leaves this one up. A hello whose
  instance id is too long closes that new socket and leaves any holder up.
  """

  @behaviour WebSock
  require Logger

  # Private-use WebSocket closes (RFC 6455, 4000-4999). The relay does not redial
  # after either code: 4001 means the name is already in use, 4002 means the
  # instance id is longer than the plane allows.
  @name_taken_close_code 4001
  @instance_too_long_close_code 4002

  defstruct name: nil, subject: nil

  @doc "Close code for a hello whose name is already held by a live uplink."
  def name_taken_close_code, do: @name_taken_close_code

  @doc "Close reason telling the rejected relay that this name is taken."
  def name_taken_reason(name) when is_binary(name) do
    ~s(name "#{name}" is in use; stop the other relay or change name)
  end

  def name_taken_reason(_name), do: "name is in use; stop the other relay or change name"

  @doc "Close code for a hello whose instance id is longer than the plane allows."
  def instance_too_long_close_code, do: @instance_too_long_close_code

  @doc "Close reason telling the rejected relay that its instance id is too long."
  def instance_too_long_reason do
    "instance id is too long; max is #{Pont.Registry.max_instance_bytes()} bytes"
  end

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
          :ok ->
            {:ok, %{state | name: params["name"]}}

          {:error, {:name_taken, name}} ->
            {:stop, :normal, {@name_taken_close_code, name_taken_reason(name)}, state}

          {:error, :instance_too_long} ->
            {:stop, :normal, {@instance_too_long_close_code, instance_too_long_reason()}, state}

          {:error, reason} ->
            {:stop, reason, state}
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
