defmodule AgentLink.Release.ERTS do
  @moduledoc """
  Chooses which Burrito targets have a published OTP.

  A target is kept when the fetcher reports HTTP 200..299, or when the spec
  sets `:custom_erts`. HTTP 404 skips that target. Windows is also skipped
  when `7z` and `7zz` are both missing. A skip does not substitute
  `:code.root_dir/0`. The plain Mix release still succeeds. Any other fetcher
  result keeps the target so the build reports that error itself.

  `AGENTLINK_CUSTOM_ERTS`, when set, keeps the Linux target and is the OTP
  archive `do_resolve/1` downloads. The target stays precompiled until then,
  so Burrito still fetches the musl runtime. The value is a URL or a local
  `.tar.gz`. A directory is refused. It is not the host ERTS. The archive's
  OTP version must be the OTP version Mix compiled with. A version that can
  be read from the URL or the filename and does not match is logged. The
  archive's NIFs then replace this release's NIFs, which can break at runtime.
  A name without an OTP version token logs that the archive was not checked.
  """

  @doc """
  Split `targets` into the ones to build and the skip messages.

  `opts` accepts `:fetcher`, `:version`, `:seven_zip?`, and `:pinned_linux`.
  The fetcher is `fun(os, cpu, version) -> {:ok, status} | {:error, term}`.
  `:pinned_linux` is `AGENTLINK_CUSTOM_ERTS`. A non-empty value keeps Linux
  without calling the fetcher.
  """
  @spec select([{atom(), keyword()}], keyword()) :: {[{atom(), keyword()}], [String.t()]}
  def select(targets, opts \\ []) when is_list(targets) and is_list(opts) do
    fetcher = Keyword.get(opts, :fetcher, default_fetcher())
    version = Keyword.get(opts, :version, Burrito.Util.get_otp_version())
    seven_zip? = Keyword.get(opts, :seven_zip?, seven_zip?())
    pinned_linux = Keyword.get(opts, :pinned_linux)

    {kept, skips} =
      Enum.reduce(targets, {[], []}, fn {name, spec}, {kept, skips} ->
        case decide(spec, version, seven_zip?, fetcher, pinned_linux) do
          :keep -> {[{name, spec} | kept], skips}
          {:skip, message} -> {kept, [message | skips]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(skips)}
  end

  @doc """
  Keep one target, or skip it.

  A 404 is a skip. A target with `:custom_erts` is kept without calling `fetcher`.
  Linux is also kept when `pinned_linux` is a non-empty binary.
  """
  @spec decide(keyword(), String.t(), boolean(), (atom(), atom(), String.t() -> term()), term()) ::
          :keep | {:skip, String.t()}
  def decide(spec, version, seven_zip?, fetcher, pinned_linux \\ nil)
      when is_list(spec) and is_binary(version) and is_boolean(seven_zip?) and
             is_function(fetcher, 3) do
    cond do
      custom_erts?(spec) ->
        :keep

      spec[:os] == :linux and is_binary(pinned_linux) and pinned_linux != "" ->
        :keep

      spec[:os] == :windows and not seven_zip? ->
        {:skip, windows_message(spec)}

      true ->
        case fetcher.(spec[:os], spec[:cpu], version) do
          {:ok, status} when status in 200..299 -> :keep
          {:ok, 404} -> {:skip, missing_message(spec, version)}
          _other -> :keep
        end
    end
  end

  @behaviour Burrito.Util.ERTSResolver

  @impl Burrito.Util.ERTSResolver
  def do_resolve(%Burrito.Builder.Target{os: :linux, erts_source: {:precompiled, _}} = target) do
    case System.get_env("AGENTLINK_CUSTOM_ERTS") do
      erts when is_binary(erts) and erts != "" ->
        target
        |> pinned_source(erts)
        |> Burrito.Util.DefaultERTSResolver.do_resolve()

      _ ->
        Burrito.Util.DefaultERTSResolver.do_resolve(target)
    end
  end

  def do_resolve(%Burrito.Builder.Target{} = target) do
    Burrito.Util.DefaultERTSResolver.do_resolve(target)
  end

  defp pinned_source(target, erts) do
    case archive_warning(erts, Burrito.Util.get_otp_version()) do
      nil -> :ok
      message -> IO.puts(:stderr, message)
    end

    cond do
      File.dir?(erts) ->
        raise "AGENTLINK_CUSTOM_ERTS must be a URL or a .tar.gz. The host ERTS is not used."

      String.starts_with?(erts, "http://") or String.starts_with?(erts, "https://") ->
        %Burrito.Builder.Target{target | erts_source: {:url, url: URI.parse(erts)}}

      String.ends_with?(erts, ".tar.gz") or String.ends_with?(erts, ".exe") ->
        %Burrito.Builder.Target{target | erts_source: {:local, path: erts}}

      true ->
        raise "AGENTLINK_CUSTOM_ERTS must be a URL or a .tar.gz. The host ERTS is not used."
    end
  end

  @doc false
  def archive_warning(erts, host) when is_binary(erts) and is_binary(host) do
    case archive_version(erts) do
      ^host ->
        nil

      nil ->
        "agentlink: AGENTLINK_CUSTOM_ERTS has no OTP version token, so the archive was not checked. " <>
          "It must be OTP #{host}, or its NIFs replace this release's NIFs and can break at runtime."

      version ->
        "agentlink: AGENTLINK_CUSTOM_ERTS is OTP #{version}. " <>
          "This release was compiled with OTP #{host}. " <>
          "A mismatched archive's NIFs replace this release's NIFs, which can break at runtime."
    end
  end

  defp archive_version(erts) do
    case Regex.run(~r/(?:OTP-|otp_)(\d+\.\d+(?:\.\d+)*)/, erts) do
      [_, version] -> version
      _ -> nil
    end
  end

  @doc false
  def published_status(os, cpu, version) do
    url =
      os
      |> Burrito.Util.ERTSUniversalMachineFetcher.fetch_version(nil, cpu, version)
      |> URI.to_string()

    case Req.request(method: :head, url: url, retry: false, receive_timeout: 20_000) do
      {:ok, %{status: status}} -> {:ok, status}
      other -> {:error, other}
    end
  end

  defp default_fetcher do
    Application.get_env(:agent_link, :erts_fetcher, &published_status/3)
  end

  defp custom_erts?(spec) do
    case spec[:custom_erts] do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp seven_zip? do
    System.find_executable("7z") != nil or System.find_executable("7zz") != nil
  end

  defp windows_message(spec) do
    "agentlink: skipping Burrito target windows #{spec[:cpu]}. " <>
      "7z is not on PATH, so the Windows OTP archive cannot be unpacked. " <>
      "The plain release is unchanged."
  end

  defp missing_message(spec, version) do
    "agentlink: skipping Burrito target #{spec[:os]} #{spec[:cpu]}. " <>
      "No published OTP #{version} (HTTP 404). The plain release is unchanged. " <>
      "This build does not substitute the host ERTS. " <>
      "To build this target, set custom_erts on it in mix.exs to a URL or a local .tar.gz of a published OTP. " <>
      "AGENTLINK_CUSTOM_ERTS is that archive for Linux and still fetches the musl runtime."
  end
end
