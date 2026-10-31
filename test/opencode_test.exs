defmodule AgentLink.OpenCodeTest do
  use ExUnit.Case, async: false

  test "write and close on something that is not a port" do
    assert AgentLink.OpenCode.write(self(), "hi") == :closed
    assert AgentLink.OpenCode.close(self()) == :ok
  end

  test "a relative symlink is resolved" do
    dir = Path.join(System.tmp_dir!(), "acp-bin-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    target = Path.join(dir, "real")
    link = Path.join(dir, "link")
    File.write!(target, "")
    File.ln_s!("real", link)
    previous = Application.get_env(:agent_link, :opencode_bin)
    Application.put_env(:agent_link, :opencode_bin, link)
    on_exit(fn -> Application.put_env(:agent_link, :opencode_bin, previous) end)
    assert AgentLink.OpenCode.bin() == target
  end

  test "a plain path is left as it is" do
    previous = Application.get_env(:agent_link, :opencode_bin)
    Application.put_env(:agent_link, :opencode_bin, "/tmp/opencode-not-a-link")
    on_exit(fn -> Application.put_env(:agent_link, :opencode_bin, previous) end)
    assert AgentLink.OpenCode.bin() == "/tmp/opencode-not-a-link"
  end
end
