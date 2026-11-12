defmodule AgentLink.Relay.TargetTest do
  use ExUnit.Case, async: true

  alias AgentLink.Relay.Target

  test "wanted selects that agent when the name is online" do
    assert Target.select("bob", ["alice", "bob"]) == {:ok, "bob"}
    assert Target.select("alice", ["alice"]) == {:ok, "alice"}
    assert Target.select("bob", ["bob", "alice", "bob"]) == {:ok, "bob"}
  end

  test "nil wanted selects the only online agent" do
    assert Target.select(nil, ["alice"]) == {:ok, "alice"}
  end

  test "a repeated name counts once, and the first occurrence keeps its place" do
    assert Target.select(nil, ["alice", "alice"]) == {:ok, "alice"}

    assert Target.select(nil, ["c", "a", "b", "a"]) ==
             {:error, "Several agents are online: \"c\", \"a\", \"b\". Pass --target NAME.\n"}
  end

  test "no online agent says that no agent is online" do
    assert Target.select(nil, []) == {:error, "No agent is online.\n"}
    assert Target.select("alice", []) == {:error, "No agent is online.\n"}
    assert Target.select("", []) == {:error, "No agent is online.\n"}
  end

  test "nil wanted with several agents lists the names and says to pass --target" do
    assert Target.select(nil, ["bob", "alice"]) ==
             {:error, "Several agents are online: \"bob\", \"alice\". Pass --target NAME.\n"}
  end

  test "a wanted name that is not online lists the online names and says to pass --target" do
    assert Target.select("zed", ["bob", "alice"]) ==
             {:error,
              "\"zed\" is not online. Online agents: \"bob\", \"alice\". Pass --target.\n"}

    assert Target.select("zed", ["alice", "alice"]) ==
             {:error, "\"zed\" is not online. Online agents: \"alice\". Pass --target.\n"}
  end

  test "an empty string is a name, and the bytes must match" do
    assert Target.select("", [""]) == {:ok, ""}
    assert Target.select(" bob ", [" bob "]) == {:ok, " bob "}

    assert Target.select("", ["alice"]) ==
             {:error, "\"\" is not online. Online agents: \"alice\". Pass --target.\n"}

    assert Target.select(" bob ", ["bob"]) ==
             {:error, "\" bob \" is not online. Online agents: \"bob\". Pass --target.\n"}

    assert Target.select("Alice", ["alice"]) ==
             {:error, "\"Alice\" is not online. Online agents: \"alice\". Pass --target.\n"}

    assert Target.select(nil, ["", "alice", ""]) ==
             {:error, "Several agents are online: \"\", \"alice\". Pass --target NAME.\n"}
  end

  test "a bad wanted or a bad online list raises ArgumentError" do
    assert_raise ArgumentError, "wanted must be a binary or nil, got: :alice", fn ->
      Target.select(:alice, ["alice"])
    end

    assert_raise ArgumentError, "online must be a list of binaries, got: \"alice\"", fn ->
      Target.select("alice", "alice")
    end

    assert_raise ArgumentError, "online names must be binaries, got: nil", fn ->
      Target.select(nil, ["alice", nil])
    end

    assert_raise ArgumentError, "online must be a list of binaries, got: nil", fn ->
      Target.select(nil, nil)
    end
  end
end
