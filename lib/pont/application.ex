defmodule Pont.Application do
  @moduledoc """
  `PONT_MODE=all` runs the plane and the sidecar in one BEAM. They still talk
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
          :plane -> plane_children()
          :agent -> [Pont.Sidecar]
          :all -> plane_children() ++ [Pont.Sidecar.Supervisor]
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

  defp plane_children do
    port = Application.fetch_env!(:pont, :port)

    [
      Pont.Registry,
      Pont.Plane,
      Pont.Setup.Watch,
      {Bandit, plug: Pont.Router, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    ]
  end
end
