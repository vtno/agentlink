defmodule Pont.Application do
  @moduledoc """
  `pont` runs the plane and the agent relay in one BEAM. `pont plane` and
  `pont agent` split them onto two machines. They still talk over the agent
  WebSocket. The link file has the plane URL.
  """

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- command(),
         :ok <- prepare(),
         :ok <- ensure_link() do
      children =
        case Application.fetch_env!(:pont, :mode) do
          :plane -> [Pont.Plane.Supervisor]
          :agent -> [Pont.Relay.Agent]
          :all -> [Pont.Plane.Supervisor, Pont.Relay.Agent.Supervisor]
        end

      Supervisor.start_link(children,
        strategy: :one_for_one,
        max_restarts: 5,
        max_seconds: 20,
        name: Pont.Supervisor
      )
    end
  end

  defp command do
    if Application.get_env(:pont, :cli, true) do
      case Pont.CLI.apply() do
        :ok -> :ok
        {:halt, code} -> System.halt(code)
        {:error, message} -> {:error, message}
      end
    else
      :ok
    end
  end

  defp prepare do
    case Pont.Setup.prepare() do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp ensure_link do
    case Application.fetch_env!(:pont, :mode) do
      :plane ->
        :ok

      _ ->
        case Pont.Link.read() do
          {:ok, _link} ->
            :ok

          {:error, message} ->
            IO.puts(:stderr, message)
            {:error, message}
        end
    end
  end
end
