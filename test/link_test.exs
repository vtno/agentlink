defmodule Pont.LinkTest do
  use ExUnit.Case, async: false

  setup do
    name = System.get_env("ACP_RUNTIME_NAME")
    url = System.get_env("ACP_PLANE_URL")
    on_exit(fn -> restore("ACP_RUNTIME_NAME", name); restore("ACP_PLANE_URL", url) end)
    System.delete_env("ACP_RUNTIME_NAME")
    System.delete_env("ACP_PLANE_URL")
    :ok
  end

  test "missing file uses the defaults" do
    link = Pont.Link.read("/tmp/does-not-exist-acp-link.json")
    assert %Pont.Link{name: "this-machine", label: "this machine", plane_url: "ws://127.0.0.1:8090/agent"} = link
  end

  test "bad json uses the defaults" do
    path = write!("{")
    assert Pont.Link.read(path).name == "this-machine"
  end

  test "label and name come from the file" do
    path = write!(~s({"name":"Lab Box","label":"Bench","plane_url":"ws://example.test/agent"}))
    link = Pont.Link.read(path)
    assert link.name == "lab-box"
    assert link.label == "Bench"
    assert link.plane_url == "ws://example.test/agent"
  end

  test "label falls back to the name, then a default" do
    path = write!(~s({"name":"Only Name"}))
    assert Pont.Link.read(path).label == "Only Name"

    path = write!(~s({}))
    assert Pont.Link.read(path).label == "this machine"
  end

  test "a name that slugs to nothing becomes opencode" do
    path = write!(~s({"name":"---"}))
    assert Pont.Link.read(path).name == "opencode"
  end

  test "environment overrides the file" do
    path = write!(~s({"name":"file","plane_url":"ws://file/agent"}))
    System.put_env("ACP_RUNTIME_NAME", "From Env")
    System.put_env("ACP_PLANE_URL", "ws://env/agent")
    link = Pont.Link.read(path)
    assert link.name == "from-env"
    assert link.plane_url == "ws://env/agent"
  end

  test "slug trims, lowercases, and caps the length" do
    assert Pont.Link.slug("  Hello, World! ") == "hello-world"
    assert Pont.Link.slug(String.duplicate("ab", 30)) == String.duplicate("ab", 20)
    assert Pont.Link.slug(nil) == ""
  end

  defp write!(body) do
    path = Path.join(System.tmp_dir!(), "acp-link-#{System.unique_integer([:positive])}.json")
    File.write!(path, body)
    path
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
