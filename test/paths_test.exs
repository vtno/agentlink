defmodule Pont.PathsTest do
  use ExUnit.Case, async: false

  test "the link file and the workspace default under ~/.pont" do
    root = Path.join(System.user_home!(), ".pont")
    assert Pont.Paths.root() == root
    assert Pont.Paths.link() == Path.join(root, "agent.link.json")
    assert Pont.Link.path() == Pont.Paths.link()
    assert Pont.Paths.default_workdir() == Path.join(root, "workspace")
  end

  test "the opencode executable defaults to PATH, then ~/.local/bin" do
    expected =
      System.find_executable("opencode") ||
        Path.join(System.user_home!(), ".local/bin/opencode")

    assert Pont.Paths.default_opencode_bin() == expected
  end

  test "application config overrides the workspace and the executable" do
    assert Pont.Paths.workdir() == "/tmp/pont-test-workdir"

    previous = Application.get_env(:pont, :opencode_bin)
    Application.put_env(:pont, :opencode_bin, "/tmp/opencode-from-config")
    on_exit(fn -> restore_bin(previous) end)
    assert Pont.Paths.opencode_bin() == "/tmp/opencode-from-config"
  end

  defp restore_bin(nil), do: Application.delete_env(:pont, :opencode_bin)
  defp restore_bin(value), do: Application.put_env(:pont, :opencode_bin, value)
end
