defmodule Pont.CLITest do
  use ExUnit.Case, async: false

  test "a wrapped binary drops the launcher prefix" do
    System.put_env("__BURRITO", "1")
    on_exit(fn -> System.delete_env("__BURRITO") end)

    assert Pont.CLI.argv_from_launch(["--no-halt", "--", "plane", "--port", "9000"]) ==
             ["plane", "--port", "9000"]
  end

  test "a normal launch does not drop the launcher prefix" do
    System.delete_env("__BURRITO")

    assert Pont.CLI.argv_from_launch(["--no-halt", "--", "plane"]) ==
             ["--no-halt", "--", "plane"]
  end

  test "the launcher prefix is not a pont argument" do
    assert Pont.CLI.drop_launcher_prefix(["--no-halt", "--", "plane", "--port", "9000"]) ==
             ["plane", "--port", "9000"]

    assert Pont.CLI.drop_launcher_prefix(["--", "plane"]) == ["--", "plane"]
    assert Pont.CLI.drop_launcher_prefix(["plane"]) == ["plane"]
  end

  test "no arguments run the plane and the relay" do
    assert {:ok, %Pont.CLI{mode: :all, port: nil, token: nil}} = Pont.CLI.parse([])
  end

  test "the root command takes a port and a token" do
    assert {:ok, %Pont.CLI{mode: :all, port: 9000, token: "sekret"}} =
             Pont.CLI.parse(["--port", "9000", "--token", "sekret"])
  end

  test "plane takes a port and a token" do
    assert {:ok, %Pont.CLI{mode: :plane, port: 9000, token: "sekret"}} =
             Pont.CLI.parse(["plane", "--port", "9000", "--token", "sekret"])
  end

  test "relay takes a token and does not listen" do
    assert {:ok, %Pont.CLI{mode: :relay, token: "sekret"}} = Pont.CLI.parse(["relay", "--token", "sekret"])
    assert {:error, message} = Pont.CLI.parse(["relay", "--port", "1", "--token", "sekret"])
    assert message =~ "does not listen"
    assert {:error, message} = Pont.CLI.parse(["relay"])
    assert message =~ "needs --token"
  end

  test "a bad command or port is rejected" do
    assert {:error, message} = Pont.CLI.parse(["nope"])
    assert message =~ "pont plane"
    assert {:error, message} = Pont.CLI.parse(["plane", "--port", "0"])
    assert message =~ "1 to 65535"
    assert {:ok, :help} = Pont.CLI.parse(["--help"])
  end

  test "relay and the root command take an OpenCode executable" do
    path = Path.join(System.tmp_dir!(), "pont-opencode-#{System.unique_integer([:positive])}")
    File.touch!(path)
    on_exit(fn -> File.rm(path) end)
    expanded = Path.expand(path)

    assert {:ok, %Pont.CLI{mode: :all, opencode_bin: ^expanded}} =
             Pont.CLI.parse(["--opencode-bin", path])

    assert {:ok, %Pont.CLI{mode: :relay, token: "sekret", opencode_bin: ^expanded}} =
             Pont.CLI.parse(["relay", "--token", "sekret", "--opencode-bin", path])

    assert {:error, message} = Pont.CLI.parse(["plane", "--opencode-bin", path])
    assert message =~ "does not run opencode"
    assert {:error, message} = Pont.CLI.parse(["--opencode-bin", path <> "-missing"])
    assert message =~ "not found"
  end

  test "apply stores the OpenCode executable" do
    path = Path.join(System.tmp_dir!(), "pont-opencode-#{System.unique_integer([:positive])}")
    File.touch!(path)
    on_exit(fn -> File.rm(path) end)
    previous = Application.get_env(:pont, :opencode_bin)
    mode = Application.get_env(:pont, :mode)

    assert :ok = Pont.CLI.apply(["--opencode-bin", path])
    assert Application.get_env(:pont, :opencode_bin) == Path.expand(path)

    restore(:opencode_bin, previous)
    restore(:mode, mode)
  end

  test "apply stores the command" do
    previous = %{
      mode: Application.get_env(:pont, :mode),
      port: Application.get_env(:pont, :port),
      plane_url: Application.get_env(:pont, :plane_url),
      token: Application.get_env(:pont, :master_token)
    }

    assert :ok = Pont.CLI.apply(["plane", "--port", "9001", "--token", "sekret"])
    assert Application.get_env(:pont, :mode) == :plane
    assert Application.get_env(:pont, :port) == 9001
    assert Application.get_env(:pont, :plane_url) == Pont.Paths.plane_url(9001)
    assert Application.get_env(:pont, :master_token) == "sekret"

    restore(:mode, previous.mode)
    restore(:port, previous.port)
    restore(:plane_url, previous.plane_url)
    restore(:master_token, previous.token)
  end

  defp restore(key, nil), do: Application.delete_env(:pont, key)
  defp restore(key, value), do: Application.put_env(:pont, key, value)
end
