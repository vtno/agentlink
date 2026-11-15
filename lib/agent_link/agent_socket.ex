defmodule AgentLink.AgentSocket do
  @moduledoc """
  The plane's agent socket. The first frame is `agentlink.uplink` and lands in the registry.
  Later frames are ACP from that runtime. A hello from the same relay stops this
  socket so the new one can take the name. A hello from another relay, while this
  name is live, closes that new socket and leaves this one up. A hello whose
  instance id is too long closes that new socket and leaves any holder up.
  Permanent rejections use `AgentLink.AgentSocketProtocol` close codes. Once registered, the socket
  routes ACP under the normalized name returned by the registry.

  The socket sends a WebSocket ping on a timer. A missed pong closes it.
  `AgentLink.Keepalive` owns that timer. The router passes the subject only,
  so a listening plane reads the environment variable, then the application
  env, then the defaults.
  """

  @behaviour WebSock
  require Logger

  defstruct name: nil, subject: nil, keepalive: nil

  @doc """
  Wait for the uplink hello. The subject is whoever the router authenticated.

  `{subject, opts}` sets the keepalive. `:ping_interval` and `:pong_timeout`
  are milliseconds. `:scheduler` defaults to `Process`. The router passes the
  subject only. See `AgentLink.Keepalive`.
  """
  @impl true
  def init(%AgentLink.Access.Subject{} = subject), do: init({subject, []})

  def init({%AgentLink.Access.Subject{} = subject, opts}) when is_list(opts) do
    keepalive = opts |> AgentLink.Keepalive.new() |> AgentLink.Keepalive.arm(self())
    {:ok, %__MODULE__{subject: subject, keepalive: keepalive}}
  end

  @doc """
  The first text frame must be agentlink.uplink. That claims the runtime name.
  Later frames are ACP from that runtime.
  """
  @impl true
  def handle_in({text, [opcode: :text]}, %__MODULE__{name: nil} = state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"method" => "agentlink.uplink", "params" => params}} when is_map(params) ->
        uplink = %AgentLink.Registry.Uplink{
          name: params["name"],
          label: params["label"],
          program: params["program"] || "opencode",
          instance: params["instance"]
        }

        case AgentLink.Registry.register(self(), uplink, state.subject) do
          {:ok, name} ->
            {:ok, %{state | name: name}}

          {:error, rejection} ->
            name = if is_binary(uplink.name), do: String.trim(uplink.name)

            close =
              {AgentLink.AgentSocketProtocol.close_code(rejection),
               AgentLink.AgentSocketProtocol.reason(rejection, name)}

            {:stop, :normal, close, state}
        end

      _ ->
        {:stop, :expected_uplink, state}
    end
  end

  def handle_in({text, [opcode: :text]}, %__MODULE__{name: name} = state) when is_binary(text) do
    AgentLink.Plane.agent_frame(name, text)
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

  @impl true
  def handle_info(:superseded, state) do
    Logger.info("agent socket superseded name=#{state.name} the same relay dialed again")
    {:stop, :normal, state}
  end

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
  def terminate(reason, state) do
    Logger.info("agent socket closed name=#{inspect(state.name)} #{inspect(reason)}")
    :ok
  end
end
