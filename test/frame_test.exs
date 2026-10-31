defmodule AgentLink.FrameTest do
  use ExUnit.Case, async: true

  test "a partial line stays buffered until the newline" do
    assert {[], ~s({"method":"hi"})} = AgentLink.Frame.take("", ~s({"method":"hi"}))

    assert {[{:ok, %{"method" => "hi"}}], ""} =
             AgentLink.Frame.take(~s({"method":"hi"}), "\n")
  end

  test "one chunk can hold several lines, and a trailing partial remains" do
    chunk = ~s({"a":1}\n{"b":2}\n{"c":)

    assert {[{:ok, %{"a" => 1}}, {:ok, %{"b" => 2}}], ~s({"c":)} =
             AgentLink.Frame.take("", chunk)
  end

  test "blank lines and whitespace-only lines are skipped" do
    chunk = "\n  \n" <> ~s({"ok":true}) <> "\r\n\n"

    assert {[{:ok, %{"ok" => true}}], ""} = AgentLink.Frame.take("", chunk)
  end

  test "a non-object line is an error and the next line is still taken" do
    chunk = "not-json\n[1]\n\"hi\"\nnull\ntrue\n" <> ~s({"ok":true}) <> "\n"

    assert {[
              {:error, "not-json"},
              {:error, "[1]"},
              {:error, "\"hi\""},
              {:error, "null"},
              {:error, "true"},
              {:ok, %{"ok" => true}}
            ], ""} = AgentLink.Frame.take("", chunk)
  end

  test "leading space on a partial line is kept for the next chunk" do
    assert {[], "  {"} = AgentLink.Frame.take("", "  {")
    assert {[{:ok, %{"a" => 1}}], ""} = AgentLink.Frame.take("  {", ~s("a":1}\n))
  end

  test "a stdio line round-trips, including unicode" do
    message = %{"method" => "session/update", "text" => "café"}
    line = IO.iodata_to_binary(AgentLink.Frame.encode_line(message))

    assert String.ends_with?(line, "\n")
    assert {[{:ok, ^message}], ""} = AgentLink.Frame.take("", line)
  end

  test "a socket payload is one object and has no newline" do
    message = %{"jsonrpc" => "2.0", "method" => "ping"}
    payload = AgentLink.Frame.encode(message)

    refute String.ends_with?(payload, "\n")
    assert {:ok, ^message} = AgentLink.Frame.decode(payload)
  end

  test "two objects on one line are one error, and the next line is still taken" do
    chunk = ~s({"a":1}{"b":2}\n{"c":3}\n)

    assert {[
              {:error, ~s({"a":1}{"b":2})},
              {:ok, %{"c" => 3}}
            ], ""} = AgentLink.Frame.take("", chunk)
  end

  test "a JSON-RPC batch line is an error" do
    line = ~s([{"jsonrpc":"2.0","method":"ping"}])

    assert {[{:error, ^line}], ""} = AgentLink.Frame.take("", line <> "\n")
  end

  test "a chunk boundary between cr and lf still yields one object" do
    assert {[], "{\"a\":1}\r"} = AgentLink.Frame.take("", "{\"a\":1}\r")
    assert {[{:ok, %{"a" => 1}}], ""} = AgentLink.Frame.take("{\"a\":1}\r", "\n")
  end

  test "a complete invalid line is an error and is not trimmed" do
    line = <<0x20, 0xFF, 0x20>>

    assert {[{:error, ^line}], ""} = AgentLink.Frame.take("", line <> "\n")
  end

  test "an invalid partial stays in the rest" do
    assert {[], <<0xFF>>} = AgentLink.Frame.take("", <<0xFF>>)
    assert {[], <<0xFF, 0xFE>>} = AgentLink.Frame.take(<<0xFF>>, <<0xFE>>)
  end

  test "a socket payload may end with whitespace, and a second value is an error" do
    assert {:ok, %{"a" => 1}} = AgentLink.Frame.decode("{\"a\":1}\n")
    assert :error = AgentLink.Frame.decode("{\"a\":1}{\"b\":2}")
    assert :error = AgentLink.Frame.decode("{\"a\":1}\n{\"b\":2}")
    assert :error = AgentLink.Frame.decode("")
    assert :error = AgentLink.Frame.decode("  ")
    assert :error = AgentLink.Frame.decode("[1]")
    assert :error = AgentLink.Frame.decode(<<0xFF>>)
  end
end
