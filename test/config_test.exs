defmodule AgentLink.ConfigTest do
  use ExUnit.Case, async: true

  alias AgentLink.Config

  test "an option wins over the environment, and the environment wins over the files" do
    root = root!()
    write_config!(root, %{"plane" => "from-file", "target" => "from-file"})
    write_token!(root, "from-file\n")

    assert {:ok, config} =
             Config.load(
               root: root,
               env: env("from-env", "from-env", "from-env"),
               plane: "from-opt",
               target: "from-opt",
               token: "from-opt"
             )

    assert config == %Config{plane: "from-opt", target: "from-opt", token: "from-opt"}

    assert {:ok, config} = Config.load(root: root, env: env("from-env", "from-env", "from-env"))
    assert config == %Config{plane: "from-env", target: "from-env", token: "from-env"}

    assert {:ok, config} = Config.load(root: root, env: %{})
    assert config == %Config{plane: "from-file", target: "from-file", token: "from-file"}
  end

  test "each field falls through on its own" do
    root = root!()
    write_config!(root, %{"plane" => "from-file", "target" => "from-file"})
    write_token!(root, "from-file")

    assert {:ok, config} =
             Config.load(
               root: root,
               env: %{"AGENTLINK_TARGET" => "from-env"},
               plane: "from-opt"
             )

    assert config == %Config{plane: "from-opt", target: "from-env", token: "from-file"}
  end

  test "a blank option or environment value falls through" do
    root = root!()
    write_config!(root, %{"plane" => "  from-file  ", "target" => "from-file"})
    write_token!(root, "from-file\n")

    assert {:ok, config} =
             Config.load(
               root: root,
               env: %{
                 "AGENTLINK_PLANE" => "  ",
                 "AGENTLINK_TARGET" => "",
                 "AGENTLINK_TOKEN" => "\n"
               },
               plane: nil,
               target: "   ",
               token: ""
             )

    assert config == %Config{plane: "from-file", target: "from-file", token: "from-file"}
  end

  test "missing files leave the fields unset" do
    assert {:ok, %Config{plane: nil, target: nil, token: nil}} =
             Config.load(root: root!(), env: %{})
  end

  test "target is optional and other config keys are ignored" do
    root = root!()
    write_config!(root, %{"plane" => "ws://plane.example/acp", "label" => "extra"})

    assert {:ok, config} = Config.load(root: root, env: %{})
    assert config == %Config{plane: "ws://plane.example/acp", target: nil, token: nil}

    write_config!(root, %{"plane" => "ws://plane.example/acp", "target" => nil})
    assert {:ok, config} = Config.load(root: root, env: %{})
    assert config == %Config{plane: "ws://plane.example/acp", target: nil, token: nil}
  end

  test "a token key in the config file is an error that names the token file" do
    root = root!()
    write_config!(root, %{"plane" => "ws://plane", "token" => "secret", "target" => "lab"})

    assert {:error, message} = Config.load(root: root, env: %{}, token: "from-opt")
    assert message =~ Path.join(root, "token")
    refute message =~ "secret"
  end

  test "a null token key is still a token key" do
    root = root!()
    File.write!(Path.join(root, "config"), ~s({"token":null}))

    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ Path.join(root, "token")
  end

  test "the token file mode is 0600 or tighter" do
    root = root!()

    write_token!(root, "secret", 0o600)
    assert {:ok, %Config{token: "secret"}} = Config.load(root: root, env: %{})

    write_token!(root, "secret", 0o400)
    assert {:ok, %Config{token: "secret"}} = Config.load(root: root, env: %{})

    write_token!(root, "secret", 0o200)
    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "Could not read #{Path.join(root, "token")}"

    write_token!(root, "secret", 0o644)
    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "0644"
    assert message =~ "0600"

    write_token!(root, "secret", 0o700)
    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "0700"
  end

  test "a token from an option skips a token file with a loose mode" do
    root = root!()
    write_token!(root, "from-file", 0o644)

    assert {:ok, %Config{token: "from-opt"}} =
             Config.load(root: root, env: %{"AGENTLINK_TOKEN" => "from-env"}, token: "from-opt")
  end

  test "a config file that is not a JSON object is an error" do
    root = root!()
    path = Path.join(root, "config")

    File.write!(path, "{")
    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "#{path} is not a JSON object"

    File.write!(path, "[]")
    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "#{path} is not a JSON object"

    File.write!(path, "")
    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "#{path} is not a JSON object"
  end

  test "a config plane that is not a string is an error" do
    root = root!()
    write_config!(root, %{"plane" => 1})

    assert {:error, message} = Config.load(root: root, env: %{}, plane: "from-opt")
    assert message =~ "#{Path.join(root, "config")} plane must be a string"
  end

  test "a directory in place of the config file is a read error" do
    root = root!()
    File.mkdir_p!(Path.join(root, "config"))

    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "Could not read #{Path.join(root, "config")}"
  end

  test "the token path must be a regular file" do
    root = root!()
    File.mkdir_p!(Path.join(root, "token"))

    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "#{Path.join(root, "token")} must be a regular file"
  end

  test "a token file that is not valid UTF-8 is an error" do
    root = root!()
    write_token!(root, <<0xFF, 0xFE>>, 0o600)

    assert {:error, message} = Config.load(root: root, env: %{})
    assert message =~ "#{Path.join(root, "token")} is not valid UTF-8"
  end

  defp env(plane, target, token) do
    %{
      "AGENTLINK_PLANE" => plane,
      "AGENTLINK_TARGET" => target,
      "AGENTLINK_TOKEN" => token
    }
  end

  defp root! do
    path =
      Path.join(System.tmp_dir!(), "agentlink-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write_config!(root, map) do
    File.write!(Path.join(root, "config"), Jason.encode!(map))
  end

  defp write_token!(root, body, mode \\ 0o600) do
    path = Path.join(root, "token")
    File.rm(path)
    File.write!(path, body)
    File.chmod!(path, mode)
    path
  end
end
