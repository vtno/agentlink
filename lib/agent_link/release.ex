defmodule AgentLink.Release do
  @moduledoc """
  Mix release steps.

  `forward_start_args/1` edits the generated `bin/<name>` and `bin/<name>.bat`
  so `start` passes the words after `start` into the VM. `start plane` is the
  release form of `agentlink plane`. The Unix script uses `shift` and `"$@"`.
  The Windows `start` path turns delayed expansion off and places `%*` after
  `--` on the `elixir.bat` line. The tail is not assigned with `set`.
  `start_iex` leaves that path and passes no user tail. `AgentLink.CLI.parse/1`
  drops a leading `start`, which `%*` still contains. This suite checks the
  generated script and does not run it on Windows.

  | Bytes | What the script does |
  | --- | --- |
  | `a!b!c` | Delayed expansion is off on the `%*` line, so each `!` stays |
  | `^` | The tail is `%*`, so a quoted `^` stays. cmd still treats an unquoted `^` as its escape when it parses that line |
  | `&`, `|`, `<`, `>` | The tail is `%*`. A quoted argument stays one argument |
  | `start` | `%*` includes that word. `parse/1` drops it |

  `elixir.bat` turns delayed expansion off before it passes `%*` to `erl.exe`,
  and it stops walking options at `--`, so the words after `--` are not
  assigned with `set` there either.

  `wrap_burrito/1` registers `AgentLink.Release.ERTS` and calls `Burrito.wrap/1`.
  When the published OTP for this host returns 404, the Linux build uses the
  local unpacked ERTS at `:code.root_dir/0`. A cross target whose published
  OTP returns 404 is skipped. A Windows target is skipped when `7z` and `7zz`
  are both absent, because Burrito unpacks that OTP with `7z`. The plain Mix
  release still succeeds.

  `forward_signals/1` wraps each Burrito binary that `mix.exs` built:
  `burrito_out/<name>_linux`, `burrito_out/<name>_macos`, and
  `burrito_out/<name>_windows.exe`. `zig cc` compiles the wrapper. The Linux
  target is `x86_64-linux-gnu` and the macOS target is `aarch64-macos`. Those
  wrappers install the signal handler before `fork`, put the Burrito process
  in its own process group, and forward one `SIGTERM` or one `SIGINT` to that
  process's direct child, which is the VM, when its start time still matches.
  The wrapper remembers that pid and start time. After the Burrito process
  exits, it keeps signaling that identity, waits `2000` milliseconds, signals
  `SIGKILL`, and exits with status 1 if the VM is still alive `2000`
  milliseconds later. A grandchild such as `erl_child_setup` is not signaled.
  The Windows target is `x86_64-windows-gnu`. That wrapper runs the Burrito
  process in a Job Object with `KILL_ON_JOB_CLOSE`, turns Ctrl-C, Ctrl-Break,
  and console close into one Ctrl-Break for the child process group, waits
  `2000` milliseconds, and calls `TerminateJobObject` if the child is still
  running. A forced stop exits with status 1. Set `AGENTLINK_BURRITO=0` to
  skip `Burrito.wrap/1` and this step. `AGENTLINK_ZIG` is the `zig`
  executable. When it is unset, `zig` on `PATH` is used, then
  `/tmp/zig-0.16.0/zig`.
  """

  @unix_needle """
    start)
      start "elixir" --no-halt
      ;;
  """

  @doc """
  Pass the words after `start` into the release VM.

  Returns the release. Raises if the generated script no longer contains the
  Elixir 1.17 `start` command this step rewrites.
  """
  def forward_start_args(release) do
    root = release_path(release)
    name = release_name(release)
    patch_file!(Path.join([root, "bin", name]), &patch_unix/1)
    patch_file!(Path.join([root, "bin", name <> ".bat"]), &patch_bat/1)
    release
  end

  @doc """
  Build the Burrito binaries, using the local ERTS when the published OTP is missing.

  Registers `AgentLink.Release.ERTS` first. A target other than this machine
  whose published OTP URL returns 404 is removed, and the step logs that skip.
  `BURRITO_TARGET` keeps the requested target and does not probe the others.
  Returns the release `Burrito.wrap/1` returns.
  """
  def wrap_burrito(release) do
    Burrito.register_erts_resolver(AgentLink.Release.ERTS)
    Burrito.wrap(keep_published_targets(release))
  end

  @doc """
  Wrap each Burrito binary that is present so a stop reaches the VM.

  Looks under `burrito_out` in `File.cwd!/0`. A map with `:burrito_out` uses
  that directory instead. A missing file is left alone, because a release
  that did not build that target has nothing to wrap. Returns the release.
  Raises when `zig` is missing or `zig cc` fails.
  """
  def forward_signals(release) do
    root = burrito_root(release)
    name = release_name(release)

    Enum.each(wrappers(), fn wrapper ->
      path = Path.join(root, name <> wrapper.suffix)

      if File.regular?(path) do
        wrap!(path, wrapper)
      end
    end)

    release
  end

  defp patch_file!(path, fun) do
    text = File.read!(path)

    case fun.(text) do
      patched when is_binary(patched) ->
        File.write!(path, patched)

      :missing ->
        raise "AgentLink.Release could not patch #{path}: the Elixir release script changed"
    end
  end

  defp patch_unix(text) do
    needle = unix_needle(newline(text))

    replacement =
      unix_lines(newline(text), [
        "  start)",
        "    shift",
        "    start \"elixir\" --no-halt -- \"$@\"",
        "    ;;",
        ""
      ])

    replace_once(text, needle, replacement)
  end

  defp unix_needle(nl) do
    String.trim_trailing(@unix_needle, "\n")
    |> String.replace("\n", nl)
    |> Kernel.<>("#{nl}")
  end

  # `%*` is the raw tail, including quotes. Assigning it with `set` parses the
  # tail a second time. Delayed expansion is turned off before the one line
  # that places `%*`, and the distribution flag is expanded before that.
  # `start_iex` jumps to `:start_plain` and keeps the original invocation.
  defp patch_bat(text) do
    nl = newline(text)
    start = ":start#{nl}"

    inserted =
      start <>
        "if not \"!REL_EXTRA!\" == \"--no-halt\" goto start_plain#{nl}" <>
        "if \"!RELEASE_DISTRIBUTION!\" == \"none\" (#{nl}" <>
        "  set RELEASE_DISTRIBUTION_FLAG=#{nl}" <>
        ") else (#{nl}" <>
        "  set RELEASE_DISTRIBUTION_FLAG=--!RELEASE_DISTRIBUTION! \"!RELEASE_NODE!\"#{nl}" <>
        ")#{nl}" <>
        "setlocal DisableDelayedExpansion#{nl}" <>
        "\"%REL_VSN_DIR%\\%REL_EXEC%.bat\" %REL_EXTRA% ^#{nl}" <>
        "  --cookie \"%RELEASE_COOKIE%\" ^#{nl}" <>
        "  %RELEASE_DISTRIBUTION_FLAG% ^#{nl}" <>
        "  --erl \"-mode %RELEASE_MODE%\" ^#{nl}" <>
        "  --erl-config \"%RELEASE_SYS_CONFIG%\" ^#{nl}" <>
        "  --boot \"%REL_VSN_DIR%\\%RELEASE_BOOT_SCRIPT%\" ^#{nl}" <>
        "  --boot-var RELEASE_LIB \"%RELEASE_ROOT%\\lib\" ^#{nl}" <>
        "  --vm-args \"%RELEASE_VM_ARGS%\" -- %*#{nl}" <>
        "goto end#{nl}" <>
        ":start_plain#{nl}"

    replace_once(text, start, inserted)
  end

  defp keep_published_targets(%{options: options} = release) do
    if System.get_env("BURRITO_TARGET") do
      release
    else
      burrito = Keyword.get(options, :burrito, [])
      targets = Keyword.get(burrito, :targets, [])
      host_os = Burrito.Util.get_current_os()

      kept =
        Enum.filter(targets, fn {_name, spec} ->
          spec[:os] == host_os or published?(spec)
        end)

      burrito = Keyword.put(burrito, :targets, kept)
      %{release | options: Keyword.put(options, :burrito, burrito)}
    end
  end

  defp published?(spec) do
    if spec[:os] == :windows and is_nil(System.find_executable("7z")) and
         is_nil(System.find_executable("7zz")) do
      IO.puts(
        :stderr,
        "agentlink: skipping Burrito target windows #{spec[:cpu]}. " <>
          "7z is not on PATH, so the Windows OTP archive cannot be unpacked. " <>
          "The plain release is unchanged."
      )

      false
    else
      published_url?(spec)
    end
  end

  defp published_url?(spec) do
    version = Burrito.Util.get_otp_version()

    url =
      spec[:os]
      |> Burrito.Util.ERTSUniversalMachineFetcher.fetch_version(nil, spec[:cpu], version)
      |> URI.to_string()

    case Req.request(method: :head, url: url, retry: false, receive_timeout: 20_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        true

      {:ok, %{status: 404}} ->
        IO.puts(
          :stderr,
          "agentlink: skipping Burrito target #{spec[:os]} #{spec[:cpu]}. " <>
            "No published OTP #{version} (HTTP 404). The plain release is unchanged."
        )

        false

      other ->
        IO.puts(
          :stderr,
          "agentlink: could not check published OTP for #{spec[:os]} #{spec[:cpu]} " <>
            "(#{inspect(other)}). The build will try that target."
        )

        true
    end
  end

  defp replace_once(text, needle, replacement) do
    if String.contains?(text, needle) do
      String.replace(text, needle, replacement, global: false)
    else
      :missing
    end
  end

  defp unix_lines(nl, lines) do
    Enum.map_join(lines, nl, & &1)
  end

  defp newline(text) do
    if String.contains?(text, "\r\n"), do: "\r\n", else: "\n"
  end

  defp wrappers do
    [
      %{
        suffix: "_linux",
        target: "x86_64-linux-gnu",
        source: "c_src/agentlink_launch.c",
        kind: :posix
      },
      %{
        suffix: "_macos",
        target: "aarch64-macos",
        source: "c_src/agentlink_launch.c",
        kind: :posix
      },
      %{
        suffix: "_windows.exe",
        target: "x86_64-windows-gnu",
        source: "c_src/agentlink_launch_win.c",
        kind: :windows
      }
    ]
  end

  defp wrap!(path, wrapper) do
    inner = inner_path(path, wrapper.kind)
    source = Path.join(File.cwd!(), wrapper.source)
    File.rename!(path, inner)
    zig = zig_executable()

    case System.cmd(zig, ["cc", "-target", wrapper.target, "-O2", "-o", path, source],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        File.chmod!(path, 0o755)

      {output, status} ->
        raise "AgentLink.Release could not compile #{source} for #{wrapper.target}: status #{status}: #{output}"
    end
  end

  defp inner_path(path, :posix), do: path <> ".burrito"

  defp inner_path(path, :windows), do: Path.rootname(path, ".exe") <> ".burrito.exe"

  defp zig_executable do
    cond do
      path = System.get_env("AGENTLINK_ZIG") ->
        path

      path = System.find_executable("zig") ->
        path

      File.regular?("/tmp/zig-0.16.0/zig") ->
        "/tmp/zig-0.16.0/zig"

      true ->
        raise "AgentLink.Release could not find zig. Set AGENTLINK_ZIG or unpack Zig 0.16.0."
    end
  end

  defp burrito_root(release) do
    case Map.get(release, :burrito_out) do
      path when is_binary(path) -> path
      _ -> Path.join(File.cwd!(), "burrito_out")
    end
  end

  defp release_path(release), do: Map.fetch!(release, :path)

  defp release_name(release) do
    release |> Map.fetch!(:name) |> to_string()
  end
end
