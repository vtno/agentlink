defmodule AgentLink.TestHelpers do
  @moduledoc "Shared test helpers."

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
    {:ok, :agentlink_stay_fixture} = :compile.file(~c"#{source}", [{:outdir, ~c"#{dir}"}])

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

  def hold_fixture!(pidfile \\ "-", quiet \\ false) do
    {exe, args} = stay_fixture!()
    # Keep the child readiness file alongside the compiled fixture.
    beam_dir = Enum.at(args, Enum.find_index(args, &(&1 == "-pa")) + 1)
    ready = Path.join(beam_dir, "child")

    script = """
    trap '' TERM HUP PIPE
    childfile=$1; pidfile=$2; quiet=$3; shift 3
    "$@" wait "$childfile" &
    child=$!
    while [ ! -s "$childfile" ]; do :; done
    line="ready $$ $child"
    [ "$pidfile" = - ] || printf '%s\\n' "$line" > "$pidfile"
    [ "$quiet" = true ] || printf '%s\\n' "$line"
    exec "$@" wait -
    """

    {System.find_executable("sh"),
     ["-c", script, "agentlink-hold", ready, pidfile, to_string(quiet), exe | args]}
  end

  def setsid_fixture! do
    {exe, args} = stay_fixture!()
    beam_dir = Enum.at(args, Enum.find_index(args, &(&1 == "-pa")) + 1)
    ready = Path.join(beam_dir, "grandchild")

    script = """
    trap '' TERM HUP PIPE
    ready=$1; setsid=$2; shift 2
    (
      "$setsid" "$@" wait "$ready" &
      wait
    ) &
    while [ ! -s "$ready" ]; do :; done
    read -r grandchild < "$ready"
    printf 'ready %s %s\\n' "$$" "$grandchild"
    wait
    """

    {System.find_executable("sh"),
     ["-c", script, "agentlink-setsid", ready, System.find_executable("setsid"), exe | args]}
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
