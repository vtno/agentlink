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

  test "release env defaults distribution without overriding an explicit value" do
    assert File.read!("rel/env.sh.eex") =~ ~s(${RELEASE_DISTRIBUTION:-none})

    assert File.read!("rel/env.bat.eex") =~
             "if not defined RELEASE_DISTRIBUTION set RELEASE_DISTRIBUTION=none"
  end

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
    assert script =~ "RELEASE_NODE|RELEASE_DISTRIBUTION"
    assert script =~ "unset ROOTDIR BINDIR EMU PROGNAME"
    assert :binary.match(script, "for name in $(env") < :binary.match(script, "SELF=$(readlink_f")

    assert length(String.split(script, "start \"elixir\" --no-halt --erl \"-noinput\" -- \"$@\"")) ==
             3

    assert length(String.split(script, "start \"elixir\" --no-halt -- \"$@\"")) == 3
    refute script =~ "Unknown command"
    assert script =~ "start_iex)\n    start \"iex\" --werl"
    bat = File.read!(Path.join(bin, name <> ".bat"))
    assert bat =~ "for /f \"delims==\" %%V in ('set RELEASE_ 2^>nul')"
    assert bat =~ "if /I not \"%%V\" == \"RELEASE_NODE\""
    assert bat =~ "if /I not \"%%V\" == \"RELEASE_DISTRIBUTION\""

    assert :binary.match(bat, "for /f \"delims==\"") <
             :binary.match(bat, "if not defined RELEASE_VSN")

    refute bat =~ "AGENTLINK_START_TAIL"
    assert bat =~ "for /f \"tokens=1,2\""
    assert bat =~ "if not \"!REL_EXTRA!\" == \"--no-halt\" goto start_plain"
    assert bat =~ "setlocal DisableDelayedExpansion"
    assert bat =~ "set AGENTLINK_WINDOWS_START=1"
    assert bat =~ ":start_plain\n"
    assert bat =~ ":cli\n"

    cli =
      bat |> String.split(":cli\n", parts: 2) |> Enum.at(1) |> String.split(":start\n") |> hd()

    refute cli =~ "for /f"
    refute cli =~ "AGENTLINK_WINDOWS_START"
    assert cli =~ "--vm-args \"%RELEASE_VM_ARGS%\" -- %*"
    assert cli =~ "if \"%~1\" == \"connect\" set AGENTLINK_VM_MODE=-mode %RELEASE_MODE% -noinput"

    start =
      bat
      |> String.split(":start\n", parts: 2)
      |> Enum.at(1)
      |> String.split(":start_plain\n")
      |> hd()

    refute start =~ "for /f"
    assert start =~ "set AGENTLINK_WINDOWS_START=1"
    assert start =~ "--vm-args \"%RELEASE_VM_ARGS%\" -- %*"

    assert start =~
             "if \"%~2\" == \"connect\" set AGENTLINK_VM_MODE=-mode %RELEASE_MODE% -noinput"

    assert_raise RuntimeError, ~r/could not patch/, fn ->
      AgentLink.Release.forward_start_args(release)
    end
  end

  defp unix_script do
    """
    SELF=$(readlink_f "$0")
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
    setlocal enabledelayedexpansion
    if not defined RELEASE_VSN (for /f "tokens=1,2" %%K in ('type "!RELEASE_ROOT!\releases\start_erl.data"') do (set ERTS_VSN=%%K) && (set RELEASE_VSN=%%L))
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
