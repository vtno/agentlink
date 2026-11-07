defmodule AgentLink.Agent.LaunchTest do
  use ExUnit.Case, async: false

  alias AgentLink.Agent.Launch
  alias AgentLink.Link

  test "malformed files return the link error" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "agentlink-launch-missing-#{System.unique_integer([:positive])}.json"
      )

    assert Launch.load(missing) == Link.read(missing)

    for body <- ["{", "[]", "", "null", "1", "\"opencode\""] do
      path = write!(body)
      assert Launch.load(path) == Link.read(path)
    end

    directory =
      Path.join(System.tmp_dir!(), "agentlink-launch-dir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    assert Launch.load(directory) == Link.read(directory)
  end

  test "command and args are required" do
    path = write!(~s({"name":"opencode","label":"this machine","program":"opencode"}))
    assert {:ok, %Link{name: "opencode", program: "opencode"}} = Link.read(path)
    assert {:error, message} = Launch.load(path)
    assert message == "#{path} must include a command.\n"

    path = write!(~s({"args":[]}))
    assert {:error, message} = Launch.load(path)
    assert message == "#{path} must include a command.\n"

    path = write!(~s({"command":"opencode"}))
    assert {:error, message} = Launch.load(path)
    assert message == "#{path} must include args.\n"
  end

  test "a command that is not a string is rejected" do
    for command <- [nil, 1, true, ["opencode"], %{"bin" => "opencode"}] do
      path = write!(Jason.encode!(%{"command" => command, "args" => []}))
      assert {:error, message} = Launch.load(path)
      assert message == "#{path} command must be a string.\n"
    end
  end

  test "a blank or relative command is rejected" do
    for command <- ["", "   ", "\n", "\t"] do
      path = write!(Jason.encode!(%{"command" => command, "args" => []}))
      assert {:error, message} = Launch.load(path)
      assert message == "#{path} command must not be blank.\n"
    end

    relatives = [
      "./opencode",
      "  ./opencode  ",
      "bin/kimi",
      ".\\opencode",
      "bin\\kimi",
      "../opencode",
      "..\\kimi",
      "C:opencode",
      "c:opencode",
      "C:",
      "C:bin\\kimi",
      ".",
      "..",
      "~/bin/opencode"
    ]

    for command <- relatives do
      path = write!(Jason.encode!(%{"command" => command, "args" => ["acp"]}))
      assert {:error, message} = Launch.load(path)
      assert message == "#{path} command must be an absolute path or a bare name.\n"
    end
  end

  test "args that are not a list of strings are rejected" do
    for args <- [
          "acp",
          1,
          nil,
          %{},
          true,
          [1],
          ["acp", nil],
          [%{"a" => "b"}],
          [["nested"]],
          [true]
        ] do
      path = write!(Jason.encode!(%{"command" => "opencode", "args" => args}))
      assert {:error, message} = Launch.load(path)
      assert message == "#{path} args must be a list of strings.\n"
    end
  end

  test "an env key is rejected and the value stays out of the error" do
    path =
      write!(
        Jason.encode!(%{
          "command" => "opencode",
          "args" => ["acp"],
          "env" => %{"TOKEN" => "secret-token"}
        })
      )

    assert {:error, message} = Launch.load(path)
    assert message == "#{path} must not contain env.\n"
    refute message =~ "secret-token"

    path = write!(~s({"env":null}))
    assert {:error, message} = Launch.load(path)
    assert message == "#{path} must not contain env.\n"

    path = write!(~s({"command":"opencode","args":[],"env":{}}))
    assert {:error, message} = Launch.load(path)
    assert message == "#{path} must not contain env.\n"
  end

  test "a bare name is trimmed and args are kept as written" do
    args = ["acp", "  keep  ", "", "--model=kimi"]

    path =
      write!(
        Jason.encode!(%{
          "name" => "Lab Box",
          "command" => "  opencode  ",
          "args" => args,
          "note" => "ignored",
          "env_file" => "not-env"
        })
      )

    assert {:ok, link, launch} = Launch.load(path)
    assert launch == %Launch{command: "opencode", args: args}
    assert link.name == "lab-box"
    assert link.label == "Lab Box"
    assert link.program == "opencode"
    assert {:ok, ^link} = Link.read(path)

    for command <- ["kimi", "codex-acp", "claude-agent-acp", "opencode.exe"] do
      path = write!(Jason.encode!(%{"command" => command, "args" => []}))
      assert {:ok, _link, %Launch{command: ^command, args: []}} = Launch.load(path)
    end

    missing_name = "agentlink-no-such-bin-#{System.unique_integer([:positive])}"
    path = write!(Jason.encode!(%{"command" => missing_name, "args" => []}))
    assert {:ok, _link, %Launch{command: ^missing_name, args: []}} = Launch.load(path)
  end

  test "an absolute path is kept when the file does not exist" do
    commands = [
      "/usr/bin/opencode",
      "/opt/homebrew/bin/opencode",
      "/usr/bin/../opencode",
      "  /usr/bin/opencode  ",
      "C:/Program Files/kimi.exe",
      "c:/opencode.exe",
      "C:\\Program Files\\kimi.exe",
      "\\opencode",
      "\\Users\\me\\kimi.exe",
      "\\\\server\\share\\codex-acp.exe",
      "//server/share/codex-acp.exe"
    ]

    for command <- commands do
      path = write!(Jason.encode!(%{"command" => command, "args" => []}))
      expected = String.trim(command)
      assert {:ok, _link, %Launch{command: ^expected, args: []}} = Launch.load(path)
    end

    missing =
      Path.join(System.tmp_dir!(), "agentlink-no-such-bin-#{System.unique_integer([:positive])}")

    path = write!(Jason.encode!(%{"command" => missing, "args" => ["--flag"]}))
    refute File.exists?(missing)
    assert {:ok, _link, %Launch{command: ^missing, args: ["--flag"]}} = Launch.load(path)
  end

  test "launch fields stay outside link equality" do
    shared = %{
      "name" => "Lab",
      "label" => "Bench",
      "program" => "kimi",
      "plane_url" => "ws://example.test/agent"
    }

    path_a =
      write!(Jason.encode!(Map.merge(shared, %{"command" => "opencode", "args" => ["acp"]})))

    path_b =
      write!(Jason.encode!(Map.merge(shared, %{"command" => "/usr/bin/kimi", "args" => []})))

    path_meta = write!(Jason.encode!(shared))

    assert {:ok, link_a, launch_a} = Launch.load(path_a)
    assert {:ok, link_b, launch_b} = Launch.load(path_b)
    assert link_a == link_b
    refute launch_a == launch_b
    refute Map.has_key?(link_a, :command)
    refute Map.has_key?(link_a, :args)

    assert {:ok, meta} = Link.read(path_meta)
    assert {:ok, from_a} = Link.read(path_a)
    assert from_a == meta
    assert link_a == meta
    assert link_a.program == "kimi"
  end

  test "a second load reads the rewritten file" do
    path = write!(~s({"command":"opencode","args":["acp"]}))
    assert {:ok, first_link, first_launch} = Launch.load(path)
    assert first_launch == %Launch{command: "opencode", args: ["acp"]}

    File.write!(path, ~s({"label":"After","command":"kimi","args":[]}))
    assert {:ok, second_link, second_launch} = Launch.load(path)
    assert second_launch == %Launch{command: "kimi", args: []}
    assert second_link.label == "After"
    refute second_link == first_link
    assert first_launch == %Launch{command: "opencode", args: ["acp"]}
  end

  test "nil reads the configured link path" do
    previous = Application.get_env(:agent_link, :link_path)
    path = write!(~s({"command":"opencode","args":["acp"]}))

    missing =
      Path.join(
        System.tmp_dir!(),
        "agentlink-launch-nil-#{System.unique_integer([:positive])}.json"
      )

    try do
      Application.put_env(:agent_link, :link_path, path)
      assert Launch.load(nil) == Launch.load(path)
      assert Launch.load() == Launch.load(path)

      Application.put_env(:agent_link, :link_path, missing)
      assert Launch.load(nil) == Link.read(nil)
      assert Launch.load() == Link.read()
    after
      restore_link(previous)
    end
  end

  defp write!(body) do
    path =
      Path.join(System.tmp_dir!(), "agentlink-launch-#{System.unique_integer([:positive])}.json")

    File.write!(path, body)
    path
  end

  defp restore_link(nil), do: Application.delete_env(:agent_link, :link_path)
  defp restore_link(path), do: Application.put_env(:agent_link, :link_path, path)
end
