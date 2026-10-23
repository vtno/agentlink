defmodule Pont.Application do
  @moduledoc """
  `PONT_MODE=all` runs the plane and the agent relay in one BEAM. They still talk
  over the agent WebSocket, so `plane` and `agent` can later be split onto
  two VMs with `PONT_PLANE_URL`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Pont.Setup.prepare()

    with :ok <- ensure_link() do
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
