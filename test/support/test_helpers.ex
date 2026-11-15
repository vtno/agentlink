defmodule AgentLink.TestHelpers do
  @moduledoc "Shared test helpers."
  import ExUnit.Assertions, only: [flunk: 1]

  def bounded_wait!(state, timeout, step, message) do
    bounded_wait_until!(state, System.monotonic_time(:millisecond) + timeout, step, message)
  end

  defp bounded_wait_until!(state, deadline, step, message) do
    case step.(state) do
      {:done, result} ->
        result

      {:continue, next} ->
        bounded_wait_until!(next, deadline, step, message)

      {:pending, next} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(message.(next))
        else
          bounded_wait_until!(next, deadline, step, message)
        end
    end
  end

  def hold_pids(pidfile) do
    with {:ok, line} <- File.read(pidfile),
         [_, parent, child] <- Regex.run(~r/ready (\d+) (\d+)/, line) do
      {String.to_integer(parent), String.to_integer(child)}
    else
      _ -> nil
    end
  end

  def compile_fixture!(source, dir, module) do
    case :compile.file(String.to_charlist(source), [
           {:outdir, String.to_charlist(dir)},
           :return_errors,
           :report_errors,
           :report_warnings
         ]) do
      {:ok, ^module} -> :ok
      {:ok, ^module, _} -> :ok
      other -> flunk("could not compile #{source}: #{inspect(other)}")
    end
  end

  def otp_executable do
    root = to_string(:code.root_dir())
    version = to_string(:erlang.system_info(:version))

    name =
      case :os.type() do
        {:win32, _} -> "erl.exe"
        _ -> "erl"
      end

    if name == "erl",
      do: Path.join([root, "bin", name]),
      else: Path.join([root, "erts-" <> version, "bin", name])
  end

  def stay_fixture! do
    dir = Path.join(System.tmp_dir!(), "agentlink-stay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    source = Path.expand("../fixtures/agentlink_stay_fixture.erl", __DIR__)

    compile_fixture!(source, dir, :agentlink_stay_fixture)

    {otp_executable(),
     [
       "+S",
       "2:2",
       "+A",
       "1",
       "-noshell",
       "-noinput",
       "-pa",
       dir,
       "-run",
       "agentlink_stay_fixture",
       "start",
       "--"
     ]}
  end

  def hold_fixture!(pidfile \\ "-", quiet \\ false, childexe \\ nil) do
    {exe, args} = stay_fixture!()
    childexe = childexe || exe
    # Keep the child readiness file alongside the compiled fixture.
    beam_dir = Enum.at(args, Enum.find_index(args, &(&1 == "-pa")) + 1)
    ready = Path.join(beam_dir, "child")

    script = """
    trap '' TERM HUP PIPE
    childfile=$1; pidfile=$2; quiet=$3; childexe=$4; reader=$5; shift 5
    mkfifo "$childfile" || exit 1
    "$childexe" "$@" ready - > "$childfile" &
    child=$!
    if ! "$reader" "$@" read "$childfile" > /dev/null; then
      rm -f "$childfile"
      echo "hold fixture child exited or did not report readiness" >&2
      exit 1
    fi
    rm -f "$childfile"
    line="ready $$ $child"
    [ "$pidfile" = - ] || printf '%s\\n' "$line" > "$pidfile"
    [ "$quiet" = true ] || printf '%s\\n' "$line"
    exec "$reader" "$@" wait -
    """

    {System.find_executable("sh"),
     ["-c", script, "agentlink-hold", ready, pidfile, to_string(quiet), childexe, exe | args]}
  end

  def setsid_fixture!(childexe \\ nil) do
    {exe, args} = stay_fixture!()
    childexe = childexe || exe
    beam_dir = Enum.at(args, Enum.find_index(args, &(&1 == "-pa")) + 1)
    ready = Path.join(beam_dir, "grandchild")

    script = """
    trap '' TERM HUP PIPE
    ready=$1; setsid=$2; childexe=$3; reader=$4; shift 4
    mkfifo "$ready" || exit 1
    (
      "$setsid" "$childexe" "$@" ready - > "$ready" &
      wait
    ) &
    grandchild=$("$reader" "$@" read "$ready") || {
      rm -f "$ready"
      echo "setsid fixture child exited or did not report readiness" >&2
      exit 1
    }
    rm -f "$ready"
    printf 'ready %s %s\\n' "$$" "$grandchild"
    wait
    """

    {System.find_executable("sh"),
     [
       "-c",
       script,
       "agentlink-setsid",
       ready,
       System.find_executable("setsid"),
       childexe,
       exe | args
     ]}
  end

  def launcher_fixture!(parent_file, child_file) do
    {exe, args} = stay_fixture!()

    script = """
    trap 'exit 0' TERM
    parent=$1; child=$2; shift 2
    "$@" child "$child" &
    printf '%s' "$$" > "$parent"
    wait
    """

    {System.find_executable("sh"),
     ["-c", script, "agentlink-launcher", parent_file, child_file, exe | args]}
  end

  def await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end

  def kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    await_down(ref, pid)
  end

  def await(fun) do
    case fun.() do
      false -> await(fun)
      nil -> await(fun)
      result -> result
    end
  end

  def capture_info(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: level)
    end
  end

  def await_pid(name), do: await(fn -> AgentLink.Registry.pid(name) end)

  def restore(key, nil), do: Application.delete_env(:agent_link, key)
  def restore(key, value), do: Application.put_env(:agent_link, key, value)
end
