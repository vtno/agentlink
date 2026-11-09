defmodule AgentLink.Release.ERTSTest do
  @moduledoc """
  The Burrito ERTS choice when the published tarball is missing.

  `decide/2` is the branch `do_resolve/1` takes after the default resolver
  raises. A 404 for this machine's OS and CPU uses `:code.root_dir/0`.
  Any other target, and any other error, stays a raise.
  """

  use ExUnit.Case, async: true

  alias Burrito.Builder.Target

  test "a 404 for this machine uses the local ERTS" do
    target = target(Burrito.Util.get_current_os(), Burrito.Util.get_current_cpu())

    assert {:local, path} =
             AgentLink.Release.ERTS.decide(target, "Failed to fetch https://example (Got 404)")

    assert path == to_string(:code.root_dir())
  end

  test "a 404 for another OS and a non-404 stay errors" do
    other =
      if Burrito.Util.get_current_os() == :windows,
        do: target(:linux, :x86_64),
        else: target(:windows, :x86_64)

    host = target(Burrito.Util.get_current_os(), Burrito.Util.get_current_cpu())

    assert :raise =
             AgentLink.Release.ERTS.decide(other, "Failed to fetch https://example (Got 404)")

    assert :raise =
             AgentLink.Release.ERTS.decide(host, "Failed to fetch https://example (Got 500)")
  end

  defp target(os, cpu) do
    %Target{
      alias: os,
      cpu: cpu,
      os: os,
      cross_build: true,
      qualifiers: [],
      erts_source: {:precompiled, version: "27.3.4.19"},
      debug?: false
    }
  end
end
