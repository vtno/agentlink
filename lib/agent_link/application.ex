defmodule AgentLink.Application do
  @moduledoc """
  `agentlink` runs the plane and the relay in one BEAM. `agentlink plane` and
  `agentlink relay` split them onto two machines. They still talk over the agent
  WebSocket. The link file holds the name, the label, the program, and the plane URL.
  """

  use Application

  # A release has no Mix. A bad command must exit. A crash dump is the wrong signal.
  @halt_boot_error Mix.env() != :test

  @impl true
  def start(_type, _args) do
    with :ok <- command(),
         :ok <- AgentLink.Setup.prepare(),
         :ok <- ensure_link() do
      children =
        case Application.fetch_env!(:agent_link, :mode) do
          :plane -> [AgentLink.Plane.Supervisor]
          :relay -> [AgentLink.Relay.Agent]
          :all -> [AgentLink.Plane.Supervisor, AgentLink.Relay.Agent.Supervisor]
        end

      Supervisor.start_link(children,
        strategy: :one_for_one,
        max_restarts: 5,
        max_seconds: 20,
        name: AgentLink.Supervisor
      )
    end
  end

  defp command do
    if Application.get_env(:agent_link, :cli, true) do
      case AgentLink.CLI.apply() do
        :ok -> :ok
        {:halt, code} -> System.halt(code)
        {:error, message} -> boot_error(message)
      end
    else
      :ok
    end
  end

  defp ensure_link do
    case Application.fetch_env!(:agent_link, :mode) do
      :plane ->
        :ok

      _ ->
        case AgentLink.Link.read() do
          {:ok, _link} ->
            :ok

          {:error, message} ->
            IO.puts(:stderr, message)
            boot_error(message)
        end
    end
  end

  defp boot_error(message) do
    if @halt_boot_error, do: System.halt(1), else: {:error, message}
  end
end
