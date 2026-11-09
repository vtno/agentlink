defmodule AgentLink.PathsTest do
  use ExUnit.Case, async: false

  test "the config file and the token file default under ~/.agentlink" do
    root = Path.join(System.user_home!(), ".agentlink")
    assert AgentLink.Paths.config() == Path.join(root, "config")
    assert AgentLink.Paths.token() == Path.join(root, "token")
  end

  test "the link file and the workspace default under ~/.agentlink" do
    root = Path.join(System.user_home!(), ".agentlink")
    assert AgentLink.Paths.root() == root
    assert AgentLink.Paths.link() == Path.join(root, "agent.link.json")
    assert AgentLink.Link.path() == AgentLink.Paths.link()
    assert AgentLink.Paths.plane_url() == "ws://127.0.0.1:8090/agent"
    assert AgentLink.Paths.plane_url(9001) == "ws://127.0.0.1:9001/agent"
  end

  test "application config overrides the workspace" do
    assert AgentLink.Paths.workdir() == "/tmp/agentlink-test-workdir"
  end
end
