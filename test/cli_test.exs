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

  test "the removed opencode bin flag is rejected" do
    for argv <- [
          ["--opencode-bin", "opencode"],
          ["relay", "--token", "sekret", "--opencode-bin", "opencode"],
          ["plane", "--opencode-bin", "opencode"],
          ["connect", "--opencode-bin", "opencode"]
        ] do
      assert {:error, message} = AgentLink.CLI.parse(argv)
      refute message =~ "--opencode-bin"
    end

    refute AgentLink.CLI.usage() =~ "opencode"
  end

  test "connect takes a plane, a target, and a token" do
    assert {:ok,
            %AgentLink.CLI{
              mode: :connect,
              plane: "wss://plane.example/acp",
              target: "lab",
              token: "sekret",
              port: nil
            }} =
             AgentLink.CLI.parse([
               "connect",
               "--token",
               "sekret",
               "--plane",
               "wss://plane.example/acp",
               "--target",
               "lab"
             ])

    assert {:ok, %AgentLink.CLI{mode: :connect, plane: nil, target: nil, token: nil}} =
             AgentLink.CLI.parse(["connect"])
  end

  test "connect rejects a blank flag, a port, and an extra argument" do
    assert {:error, message} = AgentLink.CLI.parse(["connect", "--token", ""])
    assert message =~ "agentlink connect"

    assert {:error, message} = AgentLink.CLI.parse(["connect", "--plane", ""])
    assert message =~ "agentlink connect"

    assert {:error, message} = AgentLink.CLI.parse(["connect", "--target", ""])
    assert message =~ "agentlink connect"

    assert {:error, message} =
             AgentLink.CLI.parse(["connect", "--port", "1", "--token", "sekret"])

    assert message =~ "agentlink connect"

    assert {:error, message} =
             AgentLink.CLI.parse(["connect", "--opencode-bin", "opencode", "--token", "sekret"])

    assert message =~ "agentlink connect"
    assert {:error, message} = AgentLink.CLI.parse(["connect", "extra"])
    assert message =~ "agentlink connect"
  end

  test "apply stores connect flags and leaves the master token" do
    previous = %{
      mode: Application.get_env(:agent_link, :mode),
      token: Application.get_env(:agent_link, :master_token),
      plane: Application.get_env(:agent_link, :connect_plane),
      target: Application.get_env(:agent_link, :connect_target),
      connect_token: Application.get_env(:agent_link, :connect_token)
    }

    Application.put_env(:agent_link, :connect_plane, "stale")
    Application.put_env(:agent_link, :master_token, "plane-token")

    assert :ok =
             AgentLink.CLI.apply([
               "connect",
               "--plane",
               "ws://plane.example/acp",
               "--target",
               "lab",
               "--token",
               "sekret"
             ])

    assert Application.get_env(:agent_link, :mode) == :connect
    assert Application.get_env(:agent_link, :connect_plane) == "ws://plane.example/acp"
    assert Application.get_env(:agent_link, :connect_target) == "lab"
    assert Application.get_env(:agent_link, :connect_token) == "sekret"
    assert Application.get_env(:agent_link, :master_token) == "plane-token"

    assert :ok = AgentLink.CLI.apply(["connect"])
    assert Application.get_env(:agent_link, :connect_plane) == nil
    assert Application.get_env(:agent_link, :connect_target) == nil
    assert Application.get_env(:agent_link, :connect_token) == nil
    assert Application.get_env(:agent_link, :master_token) == "plane-token"

    AgentLink.TestHelpers.restore(:mode, previous.mode)
    AgentLink.TestHelpers.restore(:master_token, previous.token)
    AgentLink.TestHelpers.restore(:connect_plane, previous.plane)
    AgentLink.TestHelpers.restore(:connect_target, previous.target)
    AgentLink.TestHelpers.restore(:connect_token, previous.connect_token)
  end

  test "an empty argv leaves the configured mode" do
    previous = Application.get_env(:agent_link, :mode)
    Application.put_env(:agent_link, :mode, :plane)
    assert :ok = AgentLink.CLI.apply([])
    assert Application.get_env(:agent_link, :mode) == :plane
    AgentLink.TestHelpers.restore(:mode, previous)
  end

  test "a release boot reads plain arguments and those words replace the mode" do
    assert release_mode(["-extra", "--no-halt", "--", "relay", "--token", "sekret"]) == "relay"
  end

  test "a release boot with no words leaves the configured mode" do
    assert release_mode([]) == "plane"
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

  defp release_mode(extra) do
    eval = ~S"""
    application:ensure_all_started(elixir),
    application:set_env(agent_link, mode, plane),
    ok = 'Elixir.AgentLink.CLI':apply(),
    {ok, Mode} = application:get_env(agent_link, mode),
    io:format("mode=~s~n", [atom_to_binary(Mode, utf8)]),
    halt().
    """

    ebin = Path.expand("_build/test/lib/agent_link/ebin")
    lib = :code.lib_dir(:elixir) |> to_string() |> Path.dirname()

    {output, status} =
      System.cmd(
        System.find_executable("erl"),
        ["-noshell", "-pa", ebin, "-eval", eval | extra],
        env: [{"RELEASE_ROOT", "/tmp"}, {"ERL_LIBS", lib}, {"__BURRITO", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    [line] =
      output |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "mode="))

    String.trim_leading(line, "mode=")
  end
end
