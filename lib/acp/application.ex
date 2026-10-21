defmodule Acp.Application do
  @moduledoc """
  `ACP_MODE=all` runs the plane and the sidecar in one BEAM. They still talk
  over the agent WebSocket, so `plane` and `agent` can later be split onto
  two VMs with `ACP_PLANE_URL`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.fetch_env!(:acp, :mode) do
        :plane -> plane_children()
        :agent -> [Acp.Sidecar]
        :all -> plane_children() ++ [Acp.Sidecar]
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 20,
      name: Acp.Supervisor
    )
  end

  defp plane_children do
    port = Application.fetch_env!(:acp, :port)

    [
      Acp.Registry,
      Acp.Plane,
      {Bandit, plug: Acp.Router, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    ]
  end
end
