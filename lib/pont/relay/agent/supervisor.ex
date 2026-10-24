defmodule Pont.Relay.Agent.Supervisor do
  @moduledoc """
  Restarts the local agent relay. When this supervisor gives up, it stops.
  The plane is not a child here, so one agent relay cannot take the plane down.
  """

  use Supervisor, restart: :transient

  @doc "Start the local agent relay under its own restart budget."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([Pont.Relay.Agent], strategy: :one_for_one, max_restarts: 5, max_seconds: 20)
  end
end
