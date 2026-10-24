defmodule Pont.CLITest do
  use ExUnit.Case, async: false

  test "no arguments run the plane and the relay" do
    assert {:ok, %Pont.CLI{mode: :all, port: nil, token: nil}} = Pont.CLI.parse([])
  end

  test "plane takes a port and a token" do
    assert {:ok, %Pont.CLI{mode: :plane, port: 9000, token: "sekret"}} =
             Pont.CLI.parse(["plane", "--port", "9000", "--token", "sekret"])
  end

  test "agent takes a token and does not listen" do
    assert {:ok, %Pont.CLI{mode: :agent, token: "sekret"}} = Pont.CLI.parse(["agent", "--token", "sekret"])
    assert {:error, message} = Pont.CLI.parse(["agent", "--port", "1", "--token", "sekret"])
    assert message =~ "does not listen"
    assert {:error, message} = Pont.CLI.parse(["agent"])
    assert message =~ "needs --token"
  end

  test "a bad command or port is rejected" do
    assert {:error, message} = Pont.CLI.parse(["nope"])
    assert message =~ "pont plane"
    assert {:error, message} = Pont.CLI.parse(["plane", "--port", "0"])
    assert message =~ "1 to 65535"
    assert {:ok, :help} = Pont.CLI.parse(["--help"])
  end

  test "apply stores the command" do
    previous = {
      Application.get_env(:pont, :mode),
      Application.get_env(:pont, :port),
      Application.get_env(:pont, :plane_url),
      Application.get_env(:pont, :master_token)
    }

    assert :ok = Pont.CLI.apply(["plane", "--port", "9001", "--token", "sekret"])
    assert Application.get_env(:pont, :mode) == :plane
    assert Application.get_env(:pont, :port) == 9001
    assert Application.get_env(:pont, :plane_url) == "ws://127.0.0.1:9001/agent"
    assert Application.get_env(:pont, :master_token) == "sekret"

    {mode, port, url, token} = previous
    if mode, do: Application.put_env(:pont, :mode, mode)
    if port, do: Application.put_env(:pont, :port, port)
    if url, do: Application.put_env(:pont, :plane_url, url)
    if token, do: Application.put_env(:pont, :master_token, token), else: Application.delete_env(:pont, :master_token)
  end
end
