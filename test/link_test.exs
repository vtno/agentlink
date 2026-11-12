defmodule AgentLink.LinkTest do
  use ExUnit.Case, async: false

  test "a missing file tells the operator to create it" do
    path = "/tmp/does-not-exist-agentlink-link.json"
    assert {:error, message} = AgentLink.Link.read(path)
    assert message =~ path
    assert message =~ "plane_url"
    assert message =~ "agent relay stops"
  end

  test "bad json is an error" do
    path = write!("{")
    assert {:error, message} = AgentLink.Link.read(path)
    assert message =~ "not a JSON object"
    assert message =~ path
  end

  test "a json array is not a link" do
    path = write!("[]")
    assert {:error, message} = AgentLink.Link.read(path)
    assert message =~ "not a JSON object"
  end

  test "a directory is a read error" do
    path =
      Path.join(System.tmp_dir!(), "agentlink-link-dir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    assert {:error, message} = AgentLink.Link.read(path)
    assert message =~ "Could not read #{path}"
  end

  test "label and name come from the file" do
    path = write!(~s({"name":"Lab Box","label":"Bench","plane_url":"ws://example.test/agent"}))
    assert {:ok, link} = AgentLink.Link.read(path)
    assert link.name == "lab-box"
    assert link.label == "Bench"
    assert link.plane_url == "ws://example.test/agent"
  end

  test "label falls back to the name, then a default" do
    path = write!(~s({"name":"Only Name"}))
    assert {:ok, link} = AgentLink.Link.read(path)
    assert link.label == "Only Name"

    path = write!(~s({}))
    assert {:ok, link} = AgentLink.Link.read(path)
    assert link.label == "this machine"
  end

  test "a name that slugs to nothing becomes opencode" do
    path = write!(~s({"name":"---"}))
    assert {:ok, link} = AgentLink.Link.read(path)
    assert link.name == "opencode"
  end

  test "slug trims, lowercases, and caps the length" do
    assert AgentLink.Link.slug("  Hello, World! ") == "hello-world"
    assert AgentLink.Link.slug(String.duplicate("ab", 30)) == String.duplicate("ab", 20)
    max = AgentLink.Registry.max_name_chars()
    assert AgentLink.Link.slug(String.duplicate("a", max + 1)) == String.duplicate("a", max)
    assert AgentLink.Link.slug(nil) == ""
  end

  defp write!(body) do
    path =
      Path.join(System.tmp_dir!(), "agentlink-link-#{System.unique_integer([:positive])}.json")

    File.write!(path, body)
    path
  end
end
