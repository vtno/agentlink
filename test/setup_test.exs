defmodule Pont.SetupTest do
  use ExUnit.Case, async: false

  setup do
    token = Application.get_env(:pont, :master_token)
    url = Application.get_env(:pont, :plane_url)
    on_exit(fn -> restore(:master_token, token); restore(:plane_url, url) end)
    :ok
  end

  test "an existing token is kept" do
    Application.put_env(:pont, :master_token, "from-env")
    assert {:ok, text} = Pont.Access.Single.prepare(:plane)
    assert text =~ "using PONT_MASTER_TOKEN"
    assert Application.get_env(:pont, :master_token) == "from-env"
  end

  test "a plane mints a token for this process" do
    Application.delete_env(:pont, :master_token)
    assert {:ok, minted_text} = Pont.Access.Single.prepare(:plane)
    minted = Application.get_env(:pont, :master_token)
    assert is_binary(minted)
    assert minted_text =~ minted
    assert minted_text =~ "Set PONT_MASTER_TOKEN"

    assert {:ok, reused} = Pont.Access.Single.prepare(:agent)
    assert Application.get_env(:pont, :master_token) == minted
    assert reused =~ "using PONT_MASTER_TOKEN"
  end

  test "an agent does not mint a token" do
    Application.delete_env(:pont, :master_token)
    assert {:error, message} = Pont.Access.Single.prepare(:agent)
    assert message =~ "PONT_MASTER_TOKEN is not set"
  end

  test "standalone mode prints a command and waits" do
    Application.put_env(:pont, :plane_url, "wss://plane.example/agent")
    Application.put_env(:pont, :master_token, "sekret")
    assert {:ok, text} = Pont.Access.Single.prepare(:plane)
    assert text =~ Pont.Access.Single.command("sekret", "wss://plane.example/agent")
    assert text =~ "Waiting for the agent relay to connect."

    assert {:ok, local} = Pont.Access.Single.prepare(:all)
    assert local =~ "sekret"
    assert local =~ Pont.Access.Single.command("sekret", "wss://plane.example/agent")
    assert local =~ "agent relay on this machine is starting"
  end

  test "the watcher reports a connection and a rejection" do
    start_supervised!(Pont.Setup.Watch)
    pid = Process.whereis(Pont.Setup.Watch)

    connected =
      ExUnit.CaptureIO.capture_io(fn ->
        Process.group_leader(pid, Process.group_leader())
        Pont.Setup.Watch.connected("opencode", "this machine")
        :sys.get_state(pid)
      end)

    rejected =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Pont.Setup.Watch.rejected("The master token did not match.")
        :sys.get_state(pid)
      end)

    assert connected =~ "Agent relay connected: opencode (this machine)."
    assert rejected =~ "master token did not match"
  end

  defp restore(key, nil), do: Application.delete_env(:pont, key)
  defp restore(key, value), do: Application.put_env(:pont, key, value)
end
