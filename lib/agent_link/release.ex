defmodule AgentLink.Release do
  @moduledoc """
  Mix release steps.

  `forward_start_args/1` edits the generated `bin/<name>` and `bin/<name>.bat`
  so `start` passes the words after `start` into the VM. `start plane` is the
  release form of `agentlink plane`. The Unix script uses `shift` and `"$@"`.
  The Windows script copies `%*` into `AGENTLINK_START_TAIL` and removes the
  first word with delayed expansion. It does not tokenize that tail, so a
  word that contains a space or a quote stays one word. `start_iex` leaves
  the tail empty.

  `forward_signals/1` wraps each Burrito binary that `mix.exs` built:
  `burrito_out/<name>_linux`, `burrito_out/<name>_macos`, and
  `burrito_out/<name>_windows.exe`. `zig cc` compiles the wrapper. The Linux
  target is `x86_64-linux-gnu` and the macOS target is `aarch64-macos`. Those
  wrappers put the Burrito process in its own process group, forward one
  `SIGTERM` or one `SIGINT` to that process's direct child, which is the VM,
  when its start time still matches, wait until the VM is gone, and exit with
  the VM's status. A grandchild such as `erl_child_setup` is not signaled.
  The Windows target is
  `x86_64-windows-gnu`. That wrapper runs the Burrito process in a Job Object
  with `KILL_ON_JOB_CLOSE`, turns Ctrl-C, Ctrl-Break, and console close into
  one Ctrl-Break for the child process group, waits, and exits with that
  process's status. Set `AGENTLINK_BURRITO=0` to skip `Burrito.wrap/1` and
  this step. `AGENTLINK_ZIG` is the `zig` executable. When it is unset, `zig`
  on `PATH` is used, then `/tmp/zig-0.16.0/zig`.
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

  # `%*` is the raw tail, including quotes. `shift` does not change `%*`,
  # so the first word is removed by substitution instead of `for /f`.
  # `start_iex` does not take that path and leaves the tail empty.
  defp patch_bat(text) do
    nl = newline(text)
    start = ":start#{nl}"

    inserted =
      start <>
        "if not \"!REL_EXTRA!\" == \"--no-halt\" goto start_plain#{nl}" <>
        "set AGENTLINK_START_TAIL=%*#{nl}" <>
        "set AGENTLINK_START_TAIL=!AGENTLINK_START_TAIL:*%1 =!#{nl}" <>
        "if \"!AGENTLINK_START_TAIL!\" == \"%1\" (#{nl}" <>
        "  set AGENTLINK_START_TAIL=#{nl}" <>
        ") else (#{nl}" <>
        "  set AGENTLINK_START_TAIL=-- !AGENTLINK_START_TAIL!#{nl}" <>
        ")#{nl}" <>
        "goto start_boot#{nl}" <>
        ":start_plain#{nl}" <>
        "set AGENTLINK_START_TAIL=#{nl}" <>
        ":start_boot#{nl}"

    vm = "  --vm-args \"!RELEASE_VM_ARGS!\"#{nl}goto end"
    passed = "  --vm-args \"!RELEASE_VM_ARGS!\" !AGENTLINK_START_TAIL!#{nl}goto end"

    with patched when is_binary(patched) <- replace_once(text, start, inserted) do
      replace_once(patched, vm, passed)
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
