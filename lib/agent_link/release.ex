defmodule AgentLink.Release do
  @moduledoc """
  Mix release steps.

  `forward_start_args/1` edits the generated `bin/<name>` and `bin/<name>.bat`
  so `start` passes the words after `start` into the VM. `start plane` is the
  release form of `agentlink plane`. The Windows script stores those words in
  `AGENTLINK_START_ARGS` and appends them after `--`. `for /f` splits that
  value on spaces, so a word that contains a space is not preserved.

  `forward_signals/1` wraps `burrito_out/<name>_linux` after `Burrito.wrap/1`.
  The wrapper forwards `SIGTERM` and `SIGINT` to the VM and exits with the VM's
  status. macOS and Windows Burrito binaries are left unchanged. Those
  launchers do not forward `SIGTERM`. Set `AGENTLINK_BURRITO=0` to skip
  `Burrito.wrap/1` and this step.
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
  Wrap the Linux Burrito binary so `SIGTERM` reaches the VM.

  Looks for `burrito_out/<name>_linux` under `File.cwd!/0`. A map with
  `:burrito_out` uses that directory instead. A missing file is left alone,
  because a release that did not build the Linux target has nothing to wrap.
  Returns the release.
  """
  def forward_signals(release) do
    path = burrito_linux_path(release)

    if File.regular?(path) do
      wrap_linux!(path)
    end

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

  defp patch_bat(text) do
    nl = newline(text)
    start = ":start#{nl}"

    inserted =
      start <>
        "set AGENTLINK_START_ARGS=%*#{nl}" <>
        "if \"!REL_EXTRA!\" == \"--no-halt\" (#{nl}" <>
        "  for /f \"tokens=1*\" %%a in (\"!AGENTLINK_START_ARGS!\") do set AGENTLINK_START_ARGS=%%b#{nl}" <>
        ") else (#{nl}" <>
        "  set AGENTLINK_START_ARGS=#{nl}" <>
        ")#{nl}"

    vm = "  --vm-args \"!RELEASE_VM_ARGS!\"#{nl}goto end"
    passed = "  --vm-args \"!RELEASE_VM_ARGS!\" -- !AGENTLINK_START_ARGS!#{nl}goto end"

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

  defp wrap_linux!(path) do
    inner = path <> ".burrito"
    source = Path.join(File.cwd!(), "c_src/agentlink_launch.c")
    File.rename!(path, inner)

    case System.cmd("gcc", ["-O2", "-o", path, source], stderr_to_stdout: true) do
      {_output, 0} ->
        File.chmod!(path, 0o755)

      {output, status} ->
        raise "AgentLink.Release could not compile #{source}: status #{status}: #{output}"
    end
  end

  defp burrito_linux_path(release) do
    root =
      case Map.get(release, :burrito_out) do
        path when is_binary(path) -> path
        _ -> Path.join(File.cwd!(), "burrito_out")
      end

    Path.join(root, release_name(release) <> "_linux")
  end

  defp release_path(release), do: Map.fetch!(release, :path)

  defp release_name(release) do
    release |> Map.fetch!(:name) |> to_string()
  end
end
