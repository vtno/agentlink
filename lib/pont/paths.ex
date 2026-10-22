defmodule Pont.Paths do
  @moduledoc """
  Where Pont keeps its own files. Defaults live under `~/.pont`.
  An environment value already loaded into the application config wins.
  """

  @doc "Directory that holds the link file and the agent workspace."
  def root, do: Path.join(System.user_home!(), ".pont")

  @doc "Link file the sidecar reads when it dials."
  def link, do: Path.join(root(), "agent.link.json")

  @doc "Workspace path before the application config overrides it."
  def default_workdir, do: Path.join(root(), "workspace")

  @doc "OpenCode executable before the application config overrides it."
  def default_opencode_bin do
    System.find_executable("opencode") || Path.join(System.user_home!(), ".local/bin/opencode")
  end

  @doc "Workspace the sidecar starts the agent in."
  def workdir, do: Application.get_env(:pont, :workdir) || default_workdir()

  @doc "OpenCode executable the sidecar spawns."
  def opencode_bin, do: Application.get_env(:pont, :opencode_bin) || default_opencode_bin()
end
