defmodule Pont.LinkTest do
  use ExUnit.Case, async: false

  setup do
    name = System.get_env("PONT_RUNTIME_NAME")
    url = System.get_env("PONT_PLANE_URL")
    on_exit(fn -> restore("PONT_RUNTIME_NAME", name); restore("PONT_PLANE_URL", url) end)
    System.delete_env("PONT_RUNTIME_NAME")
    System.delete_env("PONT_PLANE_URL")
    :ok
  end

  test "a missing file tells the operator to create it" do
    path = "/tmp/does-not-exist-acp-link.json"
    assert {:error, message} = Pont.Link.read(path)
    assert message =~ path
    assert message =~ "plane_url"
    assert message =~ "agent relay stops"
  end

  test "bad json is an error" do
    path = write!("{")
    assert {:error, message} = Pont.Link.read(path)
    assert message =~ "not a JSON object"
  end

  test "a json array is not a link" do
    path = write!("[]")
    assert {:error, message} = Pont.Link.read(path)
    assert message =~ "not a JSON object"
  end

  test "a directory is a read error" do
    path = Path.join(System.tmp_dir!(), "pont-link-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    assert {:error, message} = Pont.Link.read(path)
    assert message =~ "Could not read #{path}"
  end

  test "label and name come from the file" do
    path = write!(~s({"name":"Lab Box","label":"Bench","plane_url":"ws://example.test/agent"}))
    assert {:ok, link} = Pont.Link.read(path)
    assert link.name == "lab-box"
    assert link.label == "Bench"
    assert link.plane_url == "ws://example.test/agent"
  end

  test "label falls back to the name, then a default" do
    path = write!(~s({"name":"Only Name"}))
    assert {:ok, link} = Pont.Link.read(path)
    assert link.label == "Only Name"

    path = write!(~s({}))
    assert {:ok, link} = Pont.Link.read(path)
    assert link.label == "this machine"
  end

  test "a name that slugs to nothing becomes opencode" do
    path = write!(~s({"name":"---"}))
    assert {:ok, link} = Pont.Link.read(path)
    assert link.name == "opencode"
  end

  test "environment overrides the file" do
    path = write!(~s({"name":"file","plane_url":"ws://file/agent"}))
    System.put_env("PONT_RUNTIME_NAME", "From Env")
    System.put_env("PONT_PLANE_URL", "ws://env/agent")
    assert {:ok, link} = Pont.Link.read(path)
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
