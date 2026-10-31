defmodule AgentLink.Plane.Supervisor do
  @moduledoc """
  The plane: the registry, the sockets, and the HTTP listener.
  An agent relay is not a child here, so one agent relay cannot take the plane down.
  """

  use Supervisor

  @doc "Start the plane processes. This supervisor does not start an agent relay."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.fetch_env!(:agent_link, :port)

    Supervisor.init(
      [
        AgentLink.Registry,
        AgentLink.Plane,
        AgentLink.Setup.Watch,
        {Bandit, plug: AgentLink.Router, scheme: :http, port: port, ip: {127, 0, 0, 1}}
      ],
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 20
    )
  end
end
