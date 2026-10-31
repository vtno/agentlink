defmodule AgentLink.CLITest do
  use ExUnit.Case, async: false

  test "a wrapped binary drops the launcher prefix" do
    System.put_env("__BURRITO", "1")
    on_exit(fn -> System.delete_env("__BURRITO") end)

    assert AgentLink.CLI.argv_from_launch(["--no-halt", "--", "plane", "--port", "9000"]) ==
             ["plane", "--port", "9000"]
  end

  test "a normal launch does not drop the launcher prefix" do
    System.delete_env("__BURRITO")

    assert AgentLink.CLI.argv_from_launch(["--no-halt", "--", "plane"]) ==
             ["--no-halt", "--", "plane"]
  end

  test "the launcher prefix is not an agentlink argument" do
    assert AgentLink.CLI.drop_launcher_prefix(["--no-halt", "--", "plane", "--port", "9000"]) ==
             ["plane", "--port", "9000"]

    assert AgentLink.CLI.drop_launcher_prefix(["--", "plane"]) == ["--", "plane"]
    assert AgentLink.CLI.drop_launcher_prefix(["plane"]) == ["plane"]
  end

  test "no arguments run the plane and the relay" do
    assert {:ok, %AgentLink.CLI{mode: :all, port: nil, token: nil}} = AgentLink.CLI.parse([])
  end

  test "the root command takes a port and a token" do
    assert {:ok, %AgentLink.CLI{mode: :all, port: 9000, token: "sekret"}} =
             AgentLink.CLI.parse(["--port", "9000", "--token", "sekret"])
  end

  test "plane takes a port and a token" do
    assert {:ok, %AgentLink.CLI{mode: :plane, port: 9000, token: "sekret"}} =
             AgentLink.CLI.parse(["plane", "--port", "9000", "--token", "sekret"])
  end

  test "relay takes a token and does not listen" do
    assert {:ok, %AgentLink.CLI{mode: :relay, token: "sekret"}} =
             AgentLink.CLI.parse(["relay", "--token", "sekret"])

    assert {:error, message} = AgentLink.CLI.parse(["relay", "--port", "1", "--token", "sekret"])
    assert message =~ "does not listen"
    assert {:error, message} = AgentLink.CLI.parse(["relay"])
    assert message =~ "needs --token"
  end

  test "a bad command or port is rejected" do
    assert {:error, message} = AgentLink.CLI.parse(["nope"])
    assert message =~ "agentlink plane"
    assert {:error, message} = AgentLink.CLI.parse(["plane", "--port", "0"])
    assert message =~ "1 to 65535"
    assert {:ok, :help} = AgentLink.CLI.parse(["--help"])
  end

  test "relay and the root command take an OpenCode executable" do
    path =
      Path.join(System.tmp_dir!(), "agentlink-opencode-#{System.unique_integer([:positive])}")

    File.touch!(path)
    on_exit(fn -> File.rm(path) end)
    expanded = Path.expand(path)

    assert {:ok, %AgentLink.CLI{mode: :all, opencode_bin: ^expanded}} =
             AgentLink.CLI.parse(["--opencode-bin", path])

    assert {:ok, %AgentLink.CLI{mode: :relay, token: "sekret", opencode_bin: ^expanded}} =
             AgentLink.CLI.parse(["relay", "--token", "sekret", "--opencode-bin", path])

    assert {:error, message} = AgentLink.CLI.parse(["plane", "--opencode-bin", path])
    assert message =~ "does not run opencode"
    assert {:error, message} = AgentLink.CLI.parse(["--opencode-bin", path <> "-missing"])
    assert message =~ "not found"
  end

  test "apply stores the OpenCode executable" do
    path =
      Path.join(System.tmp_dir!(), "agentlink-opencode-#{System.unique_integer([:positive])}")

    File.touch!(path)
    on_exit(fn -> File.rm(path) end)
    previous = Application.get_env(:agent_link, :opencode_bin)
    mode = Application.get_env(:agent_link, :mode)

    assert :ok = AgentLink.CLI.apply(["--opencode-bin", path])
    assert Application.get_env(:agent_link, :opencode_bin) == Path.expand(path)

    AgentLink.TestHelpers.restore(:opencode_bin, previous)
    AgentLink.TestHelpers.restore(:mode, mode)
  end

  test "apply stores the command" do
    previous = %{
      mode: Application.get_env(:agent_link, :mode),
      port: Application.get_env(:agent_link, :port),
      plane_url: Application.get_env(:agent_link, :plane_url),
      token: Application.get_env(:agent_link, :master_token)
    }

    assert :ok = AgentLink.CLI.apply(["plane", "--port", "9001", "--token", "sekret"])
    assert Application.get_env(:agent_link, :mode) == :plane
    assert Application.get_env(:agent_link, :port) == 9001
    assert Application.get_env(:agent_link, :plane_url) == AgentLink.Paths.plane_url(9001)
    assert Application.get_env(:agent_link, :master_token) == "sekret"

    AgentLink.TestHelpers.restore(:mode, previous.mode)
    AgentLink.TestHelpers.restore(:port, previous.port)
    AgentLink.TestHelpers.restore(:plane_url, previous.plane_url)
    AgentLink.TestHelpers.restore(:master_token, previous.token)
  end
end
