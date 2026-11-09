defmodule AgentLink.Release.ERTSTest do
  @moduledoc """
  Which Burrito targets are built when a published OTP is missing.

  The fetcher is a function. A 404 skips that target, including this
  machine's OS. The decision does not return `:code.root_dir/0`. A target
  with `custom_erts` is kept. Windows without `7z` is skipped.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @targets [
    linux: [os: :linux, cpu: :x86_64],
    macos: [os: :darwin, cpu: :aarch64],
    windows: [os: :windows, cpu: :x86_64]
  ]

  test "a 404 skips the host linux target and does not use the local ERTS" do
    fetcher = fn
      :linux, :x86_64, "27.3.4.19" -> {:ok, 404}
      :darwin, :aarch64, "27.3.4.19" -> {:ok, 200}
      :windows, :x86_64, "27.3.4.19" -> {:ok, 200}
    end

    {kept, skips} =
      AgentLink.Release.ERTS.select(@targets,
        fetcher: fetcher,
        version: "27.3.4.19",
        seven_zip?: true
      )

    assert kept == [
             macos: [os: :darwin, cpu: :aarch64],
             windows: [os: :windows, cpu: :x86_64]
           ]

    assert [message] = skips
    assert message =~ "skipping Burrito target linux x86_64"
    assert message =~ "HTTP 404"
    assert message =~ "does not substitute the host ERTS"
    refute message =~ to_string(:code.root_dir())
  end

  test "a 200 keeps the target and a custom_erts pin skips the fetch" do
    fetcher = fn os, _cpu, _version ->
      send(self(), {:fetched, os})
      {:ok, 404}
    end

    targets = [
      linux: [os: :linux, cpu: :x86_64, custom_erts: "https://example.test/otp.tar.gz"]
    ]

    assert {^targets, []} =
             AgentLink.Release.ERTS.select(targets,
               fetcher: fetcher,
               version: "27.3.4.19",
               seven_zip?: true
             )

    refute_received {:fetched, _}

    assert {[linux: [os: :linux, cpu: :x86_64]], []} =
             AgentLink.Release.ERTS.select([linux: [os: :linux, cpu: :x86_64]],
               fetcher: fn _, _, _ -> {:ok, 200} end,
               version: "27.3.4.19",
               seven_zip?: true
             )
  end

  test "a pinned archive warns when its OTP version differs" do
    message =
      AgentLink.Release.ERTS.archive_warning(
        "https://example.test/OTP-27.3.4/otp_27.3.4_linux.tar.gz",
        "27.3.4.19"
      )

    assert message =~ "OTP 27.3.4"
    assert message =~ "OTP 27.3.4.19"
    assert message =~ "NIFs replace this release's NIFs"
    assert message =~ "can break at runtime"
    assert message =~ "without an OTP version token is not checked"

    assert AgentLink.Release.ERTS.archive_warning("otp_27.3.4.19_linux.tar.gz", "27.3.4.19") ==
             nil

    assert AgentLink.Release.ERTS.archive_warning("/tmp/erts.tar.gz", "27.3.4.19") == nil
  end

  test "a pinned linux archive is kept when the host OTP is a 404" do
    fetcher = fn _, _, _ ->
      send(self(), :fetched)
      {:ok, 404}
    end

    assert {[linux: [os: :linux, cpu: :x86_64]], []} =
             AgentLink.Release.ERTS.select([linux: [os: :linux, cpu: :x86_64]],
               fetcher: fetcher,
               version: "27.3.4.19",
               seven_zip?: true,
               pinned_linux: "https://example.test/otp_27.3.4.17.tar.gz"
             )

    refute_received :fetched
  end

  test "windows without 7z is skipped and a non-404 error is kept" do
    fetcher = fn
      :windows, :x86_64, _version -> {:ok, 200}
      :linux, :x86_64, _version -> {:error, :timeout}
      :darwin, :aarch64, _version -> {:ok, 200}
    end

    {kept, skips} =
      AgentLink.Release.ERTS.select(@targets,
        fetcher: fetcher,
        version: "27.3.4.19",
        seven_zip?: false
      )

    assert kept == [
             linux: [os: :linux, cpu: :x86_64],
             macos: [os: :darwin, cpu: :aarch64]
           ]

    assert [message] = skips
    assert message =~ "skipping Burrito target windows x86_64"
    assert message =~ "7z is not on PATH"
  end

  test "wrap_burrito skips the wrap when every target is a 404" do
    previous = Application.get_env(:agent_link, :erts_fetcher)

    Application.put_env(:agent_link, :erts_fetcher, fn _, _, _ -> {:ok, 404} end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :erts_fetcher, previous),
        else: Application.delete_env(:agent_link, :erts_fetcher)
    end)

    System.delete_env("BURRITO_TARGET")
    System.delete_env("AGENTLINK_CUSTOM_ERTS")

    release = %{
      name: :agentlink,
      options: [burrito: [targets: @targets]]
    }

    parent = self()

    output =
      capture_io(:stderr, fn ->
        send(parent, {:wrapped, AgentLink.Release.wrap_burrito(release)})
      end)

    assert_received {:wrapped, result}
    assert result.options[:burrito][:targets] == []
    assert output =~ "skipping Burrito target linux x86_64"
    assert output =~ "skipping the Burrito wrap"
    assert output =~ "does not substitute the host ERTS"
    refute output =~ to_string(:code.root_dir())
  end
end
