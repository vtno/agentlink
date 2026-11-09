defmodule AgentLink.LaunchTest do
  @moduledoc """
  `AgentLink.Release.forward_start_args/1` edits the generated release scripts.

  The Unix script boots `plane`, `relay`, `connect`, a flag, and no words
  through the unknown-command clause, and `start` still forwards the words
  after it. The Windows script sends those commands to `:cli` and places
  `%*` after `--` with delayed expansion off. `start` still sets
  `AGENTLINK_WINDOWS_START`. This test checks the generated text. It does
  not run the `.bat` file.
  """

  use ExUnit.Case, async: false

  test "forward_start_args passes CLI words into the release" do
    dir = unique_dir("script")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    name = "agentlink"
    File.write!(Path.join(bin, name), unix_script())
    File.write!(Path.join(bin, name <> ".bat"), bat_script())
    release = %{path: dir, name: name}
    assert AgentLink.Release.forward_start_args(release) == release
    script = File.read!(Path.join(bin, name))
    assert script =~ "shift\n    start \"elixir\" --no-halt -- \"$@\""
    assert script =~ "*)\n    start \"elixir\" --no-halt -- \"$@\""
    refute script =~ "Unknown command"
    assert script =~ "start_iex)\n    start \"iex\" --werl"
    bat = File.read!(Path.join(bin, name <> ".bat"))
    refute bat =~ "for /f"
    refute bat =~ "tokens=1*"
    refute bat =~ "AGENTLINK_START_TAIL"
    assert bat =~ "if not \"!REL_EXTRA!\" == \"--no-halt\" goto start_plain"
    assert bat =~ "setlocal DisableDelayedExpansion"
    assert bat =~ "set AGENTLINK_WINDOWS_START=1"
    assert bat =~ "--vm-args \"%RELEASE_VM_ARGS%\" -- %*"
    assert bat =~ ":start_plain\n"
    assert bat =~ ":cli\n"

    cli =
      bat |> String.split(":cli\n", parts: 2) |> Enum.at(1) |> String.split(":start\n") |> hd()

    refute cli =~ "AGENTLINK_WINDOWS_START"
    assert cli =~ "--vm-args \"%RELEASE_VM_ARGS%\" -- %*"

    assert_raise RuntimeError, ~r/could not patch/, fn ->
      AgentLink.Release.forward_start_args(release)
    end
  end

  defp unix_script do
    """
    case $1 in
      start)
        start "elixir" --no-halt
        ;;

      start_iex)
        start "iex" --werl
        ;;

      *)
        echo "Usage: $(basename "$0") COMMAND [ARGS]
    unknown
    "
        if [ -n "$1" ]; then
          echo "ERROR: Unknown command $1" >&2
          exit 1
        fi
        ;;
    esac
    """
  end

  defp bat_script do
    """
    echo Usage: %~nx0 COMMAND [ARGS]
    echo.
    if not "%~1" == "" (
      echo ERROR: Unknown command %~1
      exit /B 1
    )
    goto end

    :start
    if "!RELEASE_DISTRIBUTION!" == "none" (
      set RELEASE_DISTRIBUTION_FLAG=
    ) else (
      set RELEASE_DISTRIBUTION_FLAG=--!RELEASE_DISTRIBUTION! "!RELEASE_NODE!"
    )
    "!REL_VSN_DIR!\\!REL_EXEC!.bat" !REL_EXTRA! ^
      --vm-args "!RELEASE_VM_ARGS!"
    goto end
    """
  end

  defp unique_dir(name) do
    dir = Path.join(System.tmp_dir!(), "agentlink-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
