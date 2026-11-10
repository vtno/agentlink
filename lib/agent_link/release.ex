defmodule AgentLink.Release do
  @moduledoc """
  Mix release steps.

  `forward_start_args/1` edits the generated `bin/<name>` and `bin/<name>.bat`
  so the CLI words reach the VM. `bin/agentlink`, `bin/agentlink plane`,
  `bin/agentlink relay`, `bin/agentlink connect`, and a leading flag boot the
  release. The script places those words after `--`, including when the list
  is empty. `bin/agentlink start` still boots the release and passes the words
  after `start`. `AgentLink.CLI` reads
  `:init.get_plain_arguments/0` when `RELEASE_ROOT` is set.

  The Unix script calls `start` with `"$@"`. The Windows script places `%*`
  after `--` with delayed expansion off. The tail is not assigned with `set`.
  `bin/agentlink.bat start` sets `AGENTLINK_WINDOWS_START=1` because `%*`
  still begins with `start`. `argv_from_launch/1` drops that one word only
  when `:os.type/0` is `{:win32, _}` and the variable is `1`. A direct
  `plane`, `relay`, or `connect` does not set the variable. This suite checks
  the generated script and does not run it on Windows.

  | Bytes | What the script does |
  | --- | --- |
  | `a!b!c` | Delayed expansion is off on the `%*` line, so each `!` stays |
  | `^` | The tail is `%*`, so a quoted `^` stays. cmd still treats an unquoted `^` as its escape when it parses that line |
  | `&`, `|`, `<`, `>` | The tail is `%*`. A quoted argument stays one argument |
  | `start` | The Windows `start` path sets `AGENTLINK_WINDOWS_START=1`. `argv_from_launch/1` drops one leading `start` only when that variable is `1`. `parse/1` does not. `start start` is a usage error |

  `elixir.bat` turns delayed expansion off before it passes `%*` to `erl.exe`,
  and it stops walking options at `--`, so the words after `--` are not
  assigned with `set` there either.
  """

  @unix_needle """
    start)
      start "elixir" --no-halt
      ;;
  """

  @doc """
  Pass CLI words into the release VM.

  Returns the release. Raises if the generated script no longer contains the
  Elixir 1.17 `start` command or the unknown-command clause this step rewrites.
  """
  def forward_start_args(release) do
    root = release_path(release)
    name = release_name(release)
    patch_file!(Path.join([root, "bin", name]), &patch_unix/1)
    patch_file!(Path.join([root, "bin", name <> ".bat"]), &patch_bat/1)
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
    nl = newline(text)
    needle = unix_needle(nl)

    replacement =
      unix_lines(nl, [
        "  start)",
        "    shift",
        "    start \"elixir\" --no-halt -- \"$@\"",
        "    ;;",
        ""
      ])

    with patched when is_binary(patched) <- replace_once(text, needle, replacement) do
      replace_catch_all(patched, nl)
    end
  end

  defp replace_catch_all(text, nl) do
    pattern =
      Regex.compile!(
        "^  \\*\\)" <> Regex.escape(nl) <> ".*?" <> Regex.escape(nl <> "    ;;" <> nl),
        "ms"
      )

    replacement =
      unix_lines(nl, [
        "  *)",
        "    start \"elixir\" --no-halt -- \"$@\"",
        "    ;;",
        ""
      ])

    case Regex.replace(pattern, text, replacement, global: false) do
      ^text -> :missing
      patched -> patched
    end
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
    with patched when is_binary(patched) <- patch_bat_start(text) do
      patch_bat_cli(patched)
    end
  end

  defp patch_bat_start(text) do
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
        "set AGENTLINK_WINDOWS_START=1#{nl}" <>
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

  defp patch_bat_cli(text) do
    nl = newline(text)
    marker = "echo Usage: %~nx0 COMMAND [ARGS]#{nl}"
    label = "#{nl}:start#{nl}"

    case :binary.split(text, marker) do
      [before, rest] ->
        case :binary.split(rest, label) do
          [_usage, after_label] ->
            before <> cli_block(nl) <> label <> after_label

          _ ->
            :missing
        end

      _ ->
        :missing
    end
  end

  defp cli_block(nl) do
    ":cli#{nl}" <>
      "if \"!RELEASE_DISTRIBUTION!\" == \"none\" (#{nl}" <>
      "  set RELEASE_DISTRIBUTION_FLAG=#{nl}" <>
      ") else (#{nl}" <>
      "  set RELEASE_DISTRIBUTION_FLAG=--!RELEASE_DISTRIBUTION! \"!RELEASE_NODE!\"#{nl}" <>
      ")#{nl}" <>
      "setlocal DisableDelayedExpansion#{nl}" <>
      "\"%REL_VSN_DIR%\\elixir.bat\" --no-halt ^#{nl}" <>
      "  --cookie \"%RELEASE_COOKIE%\" ^#{nl}" <>
      "  %RELEASE_DISTRIBUTION_FLAG% ^#{nl}" <>
      "  --erl \"-mode %RELEASE_MODE%\" ^#{nl}" <>
      "  --erl-config \"%RELEASE_SYS_CONFIG%\" ^#{nl}" <>
      "  --boot \"%REL_VSN_DIR%\\%RELEASE_BOOT_SCRIPT%\" ^#{nl}" <>
      "  --boot-var RELEASE_LIB \"%RELEASE_ROOT%\\lib\" ^#{nl}" <>
      "  --vm-args \"%RELEASE_VM_ARGS%\" -- %*#{nl}" <>
      "goto end#{nl}"
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

  defp release_path(release), do: Map.fetch!(release, :path)

  defp release_name(release) do
    release |> Map.fetch!(:name) |> to_string()
  end
end
