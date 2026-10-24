defmodule Pont.CLITest do
  use ExUnit.Case, async: false

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
