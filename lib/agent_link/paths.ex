defmodule AgentLink.Paths do
  @moduledoc """
  Where AgentLink keeps its own files. Defaults live under `~/.agentlink`.
  An environment value already loaded into the application config wins.
  """

  @doc "Directory that holds the link file and the agent workspace."
  def root, do: Path.join(System.user_home!(), ".agentlink")

  @doc "Link file the uplink reads when it dials."
  def link do
    Application.get_env(:agent_link, :link_path) || Path.join(root(), "agent.link.json")
  end

  @doc "JSON file with the plane URL and an optional target."
  def config, do: Path.join(root(), "config")

  @doc "Token file."
  def token, do: Path.join(root(), "token")

  @doc "Plane WebSocket the uplink dials on this machine."
  def plane_url(port \\ 8090) when is_integer(port) and port >= 1 and port <= 65_535 do
    "ws://127.0.0.1:#{port}/agent"
  end

  @doc "Workspace path before the application config overrides it."
  def default_workdir, do: Path.join(root(), "workspace")

  @doc "OpenCode executable before the application config overrides it."
  def default_opencode_bin do
    System.find_executable("opencode") || Path.join(System.user_home!(), ".local/bin/opencode")
  end

  @doc "Workspace the agent relay opens the agent in."
  def workdir, do: Application.get_env(:agent_link, :workdir) || default_workdir()

  @doc "OpenCode executable. `AgentLink.OpenCode` runs it."
  def opencode_bin, do: Application.get_env(:agent_link, :opencode_bin) || default_opencode_bin()
end
