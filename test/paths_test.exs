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

  test "the opencode executable defaults to PATH, then ~/.local/bin" do
    expected =
      System.find_executable("opencode") ||
        Path.join(System.user_home!(), ".local/bin/opencode")

    assert AgentLink.Paths.default_opencode_bin() == expected
  end

  test "application config overrides the workspace and the executable" do
    assert AgentLink.Paths.workdir() == "/tmp/agentlink-test-workdir"

    previous = Application.get_env(:agent_link, :opencode_bin)
    Application.put_env(:agent_link, :opencode_bin, "/tmp/opencode-from-config")
    on_exit(fn -> AgentLink.TestHelpers.restore(:opencode_bin, previous) end)
    assert AgentLink.Paths.opencode_bin() == "/tmp/opencode-from-config"
  end
end
