defmodule AgentLink.SetupTest do
  use ExUnit.Case, async: false

  setup do
    token = Application.get_env(:agent_link, :master_token)
    url = Application.get_env(:agent_link, :plane_url)

    on_exit(fn ->
      AgentLink.TestHelpers.restore(:master_token, token)
      AgentLink.TestHelpers.restore(:plane_url, url)
    end)

    :ok
  end

  test "an existing token is kept" do
    Application.put_env(:agent_link, :master_token, "from-env")
    assert {:ok, text} = AgentLink.Access.Single.prepare(:plane)
    assert text =~ "using the configured token."
    assert Application.get_env(:agent_link, :master_token) == "from-env"
  end

  test "a missing token is rejected without minting" do
    Application.delete_env(:agent_link, :master_token)

    for mode <- [:plane, :all, :relay] do
      assert {:error, _} = AgentLink.Access.Single.prepare(mode)
      refute Application.get_env(:agent_link, :master_token)
    end
  end

  test "startup instructions never contain the token" do
    Application.put_env(:agent_link, :plane_url, "wss://plane.example/agent")
    Application.put_env(:agent_link, :master_token, "sekret")

    for mode <- [:plane, :all] do
      assert {:ok, text} = AgentLink.Access.Single.prepare(mode)
      refute text =~ "sekret"
      assert text =~ "AGENTLINK_TOKEN"
      assert text =~ "$HOME/.agentlink/token"
      assert text =~ "agentlink relay"
    end
  end

  test "the watcher reports a connection and a rejection" do
    start_supervised!(AgentLink.Setup.Watch)
    pid = Process.whereis(AgentLink.Setup.Watch)

    connected =
      ExUnit.CaptureIO.capture_io(fn ->
        Process.group_leader(pid, Process.group_leader())
        AgentLink.Setup.Watch.connected("opencode", "this machine")
        :sys.get_state(pid)
      end)

    rejected =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        AgentLink.Setup.Watch.rejected("The master token did not match.")
        :sys.get_state(pid)
      end)

    assert connected =~ "Uplink connected: opencode (this machine)."
    assert rejected =~ "master token did not match"
  end
end
