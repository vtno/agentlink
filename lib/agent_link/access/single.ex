defmodule AgentLink.Access.Single do
  @moduledoc """
  One operator. The configured token identifies an admin who owns and may use
  every uplink. Startup instructions do not include the token.
  """

  @behaviour AgentLink.Access

  @impl true
  def authenticate(conn) do
    if AgentLink.Auth.enabled?() and AgentLink.Auth.allowed?(conn) do
      {:ok, %AgentLink.Access.Subject{id: "admin", role: :admin}}
    else
      :reject
    end
  end

  @impl true
  def allowed?(%AgentLink.Access.Subject{role: :admin}, name) when is_binary(name), do: true
  def allowed?(%AgentLink.Access.Subject{}, name) when is_binary(name), do: false

  @impl true
  def claim(%AgentLink.Access.Subject{role: :admin}, name) when is_binary(name), do: :ok
  def claim(%AgentLink.Access.Subject{}, name) when is_binary(name), do: :reject

  @impl true
  def prepare(mode) do
    if AgentLink.Auth.enabled?() do
      {:ok, message(mode)}
    else
      {:error, "A token is required.\n"}
    end
  end

  defp message(mode) do
    url = Application.get_env(:agent_link, :plane_url) || AgentLink.Paths.plane_url()
    root = Application.get_env(:agent_link, :config_root, AgentLink.Paths.root())
    path = Path.join(root, Path.basename(AgentLink.Paths.token()))

    case mode do
      :plane ->
        """
        AgentLink is using the configured token.
        On the machine that should host the agent, set AGENTLINK_TOKEN or write the same token to #{path}, then run:

        agentlink relay

        The plane listens on 127.0.0.1. On that machine, set plane_url in the link file to an address it can reach. This plane is #{url} when it is this machine.
        Waiting for the uplink to connect.
        """

      :all ->
        """
        AgentLink is using the configured token.
        The agent relay on this machine is starting.
        To start a relay on another machine, set AGENTLINK_TOKEN or write the same token to #{path} there, then run:

        agentlink relay
        """

      :relay ->
        "AgentLink is using the configured token.\nThe uplink will dial the plane_url in the link file.\n"
    end
  end
end
