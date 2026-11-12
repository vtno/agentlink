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
    assert text =~ "using the token from --token."
    assert Application.get_env(:agent_link, :master_token) == "from-env"
  end

  test "a plane mints a token for this process" do
    Application.delete_env(:agent_link, :master_token)
    assert {:ok, minted_text} = AgentLink.Access.Single.prepare(:plane)
    minted = Application.get_env(:agent_link, :master_token)
    assert is_binary(minted)
    assert minted_text =~ minted
    assert minted_text =~ "Pass the same --token"

    assert {:ok, reused} = AgentLink.Access.Single.prepare(:relay)
    assert Application.get_env(:agent_link, :master_token) == minted
    assert reused =~ "using the configured token."
  end

  test "an agent does not mint a token" do
    Application.delete_env(:agent_link, :master_token)
    assert {:error, message} = AgentLink.Access.Single.prepare(:relay)
    assert message =~ "Pass --token"
  end

  test "standalone mode prints a command and waits" do
    Application.put_env(:agent_link, :plane_url, "wss://plane.example/agent")
    Application.put_env(:agent_link, :master_token, "sekret")
    assert {:ok, text} = AgentLink.Access.Single.prepare(:plane)
    assert text =~ AgentLink.Access.Single.command("sekret")
    assert text =~ "Waiting for the uplink to connect."

    assert {:ok, local} = AgentLink.Access.Single.prepare(:all)
    assert local =~ "sekret"
    assert local =~ AgentLink.Access.Single.command("sekret")
    assert local =~ "agent relay on this machine is starting"
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
