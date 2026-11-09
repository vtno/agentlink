defmodule AgentLink.Agent.Process do
  @moduledoc """
  Open an `AgentLink.Agent.Launch` from the caller.

  `open/3`, `write/2`, and `close/1` run in the caller. This module does not
  start a GenServer. `open/3` is the `AgentLink.Agent` callback. The relay
  calls it. The handle is the port. `open/3` does not read the link file,
  does not call `AgentLink.Agent.Launch.load/1`, and does not read application
  config. `close/1` reads `:agent_stop_timeout`. `open/4` takes a finder and
  is not a callback.
  """

  @behaviour AgentLink.Agent

  alias AgentLink.Agent.Launch

  require Logger

  # One `kill` invocation and the `/proc` scan that precedes it.
  # `AgentLink.Relay.Agent` reserves the same amount, twice, in the shutdown.
  # `allowance_ms/0` is that shared number.
  @stop_step_ms 1_000

  @doc false
  def allowance_ms, do: @stop_step_ms

  defmodule Record do
    @moduledoc false
    defstruct [:os_pid, :starttime, :group]
  end

  defmodule Identity do
    @moduledoc false
    defstruct [:pgrp, :ppid, :starttime]
  end

  defmodule Owned do
    @moduledoc false
    defstruct [:pid, :starttime, :pgrp, :root, :group]
  end

  @doc """
  Open `launch` in `cwd`. The caller must be `owner`.

  Returns `{:ok, port}` or `{:error, message}`. Stdout arrives at the caller
  as `{port, {:data, binary}}`.

  When the caller is not `owner`, the error names `owner` and the command.
  That call does not use the finder and does not spawn.

  A bare name contains neither `/` nor `\\` and is not `.`, `..`, or a
  drive-relative form such as `C:opencode`. A bare name is passed to the
  finder.   `open/3` calls `open/4` with `&System.find_executable/1`.
  `open/4` takes a finder so a test can pass a function. `open/5` takes
  that finder and a listener pid. `open/3` and `open/4` pass `nil`. Neither
  reads application config. `nil` from the finder is an error that names
  the command.

  A path that is absolute on this host is used unchanged. It is not passed
  to the finder. It is not expanded against `cwd` or the VM cwd. On Unix, a
  host-absolute path starts with `/`. On Windows, `:os.type/0` returns
  `{:win32, _}` and a host-absolute path starts with two slashes, or with a
  drive letter, a colon, and a slash. Each of those two slashes may be `/`
  or `\\`. The slash after the colon may be `/` or `\\`. On Windows, a single leading
  slash is not absolute. `AgentLink.Agent.Launch` accepts a POSIX path, a UNC path, and a
  drive path on every host. `open/3` accepts only a path that is absolute
  on this host.

  Any other command is an error that names the command. The finder is not
  called. `File.stat/1` is not called.

  `File.stat/1` must report a regular file. `File.stat/1` follows symlinks.
  The Unix execute bit is not checked. A stat error names the path. A file
  that is not regular names the path and the `File.Stat` type as a word,
  such as `directory`.

  The port is `Port.open/2` with `{:spawn_executable, path}` and `:binary`,
  `:exit_status`, `:use_stdio`, `{:args, args}`, and `{:cd, cwd}`. `:env`
  is the VM environment without `AGENTLINK_WINDOWS_START`. `:stderr_to_stdout`
  is omitted. `ErlangError` and `ArgumentError` from `Port.open/2` are
  returned as an error that names the path and the reason from the spawn.
  The OS decides that reason.

  On Linux the VM's port spawn makes the command a session leader. That pid
  is the process group leader. On Linux, `close/1` also records each
  descendant, including one that called `setsid`. On macOS, `close/1` closes
  stdin and does not signal a process group, does not walk descendants, and
  does not create a Job Object. On Windows, `close/1` closes stdin and does
  not signal a process group and does not create a Job Object.
  """
  @impl true
  @spec open(pid, Launch.t(), String.t()) :: {:ok, port} | {:error, String.t()}
  def open(owner, %Launch{} = launch, cwd) when is_pid(owner) do
    open(owner, launch, cwd, &System.find_executable/1, nil)
  end

  @doc """
  Open `launch` in `cwd` with `finder`. The caller must be `owner`.

  `open/3` is the `AgentLink.Agent` callback. `open/4` and `open/5` are not.
  `listener` receives `{:agent_opening, owner}` before the spawn. `nil` sends nothing.
  """
  @spec open(pid, Launch.t(), String.t(), (String.t() -> String.t() | nil)) ::
          {:ok, port} | {:error, String.t()}
  def open(owner, %Launch{} = launch, cwd, finder)
      when is_pid(owner) and is_function(finder, 1) do
    open(owner, launch, cwd, finder, nil)
  end

  @doc false
  def open(owner, %Launch{command: command, args: args}, cwd, finder, listener)
      when is_pid(owner) and is_function(finder, 1) do
    if owner == self() do
      open_command(command, args, cwd, finder, listener)
    else
      {:error, owner_error(owner, command)}
    end
  end

  @doc """
  Write `data` to the port's stdin.

  Returns `:ok` when `Port.info/1` shows an open port. Returns `:closed`
  otherwise.
  """
  @impl true
  @spec write(term, iodata) :: :ok | :closed
  def write(port, data) do
    if is_port(port) and Port.info(port) do
      Port.command(port, data)
      :ok
    else
      :closed
    end
  end

  @doc """
  Stop the process `open/3` started and close `port`.

  Returns `:ok` when every recorded process is gone. A second call, with no
  record left, also returns `:ok`. Returns `{:error, :timeout}` when a
  recorded process is still present after `SIGKILL`. Returns
  `{:error, :no_kill}` when `kill` is not on `PATH`.

  On Linux, when `open/3` recorded an OS pid, `close/1` reads `/proc` and
  records that pid and each descendant, including a descendant that called
  `setsid`. It signals a pid only when `/proc/<pid>/stat` still has the
  recorded start time. A process group leader is signaled with the group id,
  which is the negative pid. A descendant whose process group is not that
  pid is signaled by its own pid. The first signal is `SIGTERM`. `close/1`
  then closes the port, which closes the child's stdin, and waits until
  every recorded start time no longer matches.

  The `SIGTERM` wait is `:agent_stop_timeout` milliseconds.
  `Application.get_env/3` reads `:agent_link, :agent_stop_timeout`. The
  default is `5000`. When a recorded start time still matches at that
  deadline, `close/1` signals `SIGKILL` the same way and waits again. That
  confirmation wait is `:agent_stop_timeout`, or `1000` milliseconds when
  that value is shorter, so a timeout of `0` still observes the reap.
  `close/1` reads `/proc` again immediately before `SIGKILL` and refreshes
  each recorded process group. `close/1` does not return `:ok` while a
  recorded process remains. A remaining `{pid, starttime}` is passed to
  `AgentLink.Agent.Reaper.retain/1`. When that process is not running,
  `retain/1` writes the pairs into this VM's record file and returns
  `{:error, :noproc}`. `close/1` returns that error. The next `reap/0`
  reads the file before `open/3`. `AgentLink.Relay.Agent`
  sizes its shutdown to hold both waits and both `kill` commands.

  A pid whose start time changed is left alone. `close/1` does not signal
  the VM's own OS pid. On macOS, `close/1` closes stdin and does not signal
  a process group, does not walk descendants, and does not create a Job
  Object. On Windows, `close/1` closes stdin and does not signal a process
  group and does not create a Job Object.
  """
  @impl true
  @spec close(term) ::
          :ok
          | {:error, :timeout}
          | {:error, :no_kill}
          | {:error, :kill_failed}
          | {:error, :noproc}
  def close(port) do
    case take_record(port) do
      nil ->
        close_port(port)

      record ->
        owned = snapshot(record)
        term = signal_owned(owned, :term)
        close_port(port)
        timeout = stop_timeout()

        case wait_gone(owned, timeout) do
          :gone ->
            signal_error(term)

          :timeout ->
            owned = refresh(rescan(record, owned))
            kill = signal_owned(owned, :kill)

            case wait_gone(owned, confirm_timeout(timeout)) do
              :gone ->
                signal_error(term)

              :timeout ->
                case retain_alive(owned) do
                  :ok -> signal_error(first_error([kill, {:error, :timeout}]))
                  {:error, reason} -> {:error, reason}
                end
            end
        end
    end
  end

  @doc """
  Signal `SIGKILL` to each `{pid, starttime}` whose start time still matches.

  Waits `1000` milliseconds. Returns `:ok` when every start time is gone.
  Returns `{:error, :no_kill}` when `kill` is not on `PATH` and a pid remains.
  Returns `{:error, :kill_failed}` when `kill` exits non-zero and that start
  time still matches. Returns `{:error, :timeout}` when a start time still
  matches after the wait. Does not signal pid 1 or this VM's OS pid.
  `AgentLink.Agent.Reaper` calls this. `close/1` does not.
  """
  @spec force([{integer(), String.t()}]) ::
          :ok | {:error, :timeout} | {:error, :no_kill} | {:error, :kill_failed}
  def force(identities) when is_list(identities) do
    owned =
      Enum.flat_map(identities, fn
        {pid, starttime} when is_integer(pid) and is_binary(starttime) ->
          case read_identity(pid) do
            {:ok, %Identity{starttime: ^starttime, pgrp: pgrp}} ->
              [%Owned{pid: pid, starttime: starttime, pgrp: pgrp, root: false, group: false}]

            _ ->
              []
          end

        _ ->
          []
      end)

    case owned do
      [] ->
        :ok

      _ ->
        case signal_owned(owned, :kill) do
          {:error, :no_kill} = error ->
            error

          kill ->
            case wait_gone(owned, @stop_step_ms) do
              :gone -> :ok
              :timeout -> signal_error(first_error([kill, {:error, :timeout}]))
            end
        end
    end
  end

  @doc false
  def same_start?(pid, starttime) when is_integer(pid) and is_binary(starttime) do
    matching?(pid, starttime)
  end

  @doc false
  def starttime(pid) when is_integer(pid) do
    case read_identity(pid) do
      {:ok, %Identity{starttime: starttime}} -> starttime
      _ -> nil
    end
  end

  @doc false
  def port_env do
    System.get_env()
    |> Map.delete("AGENTLINK_WINDOWS_START")
    |> Enum.map(fn {key, value} -> {:binary.bin_to_list(key), :binary.bin_to_list(value)} end)
  end

  defp open_command(command, args, cwd, finder, listener) do
    if is_pid(listener), do: send(listener, {:agent_opening, self()})

    case resolve(command, finder) do
      {:ok, path} -> open_regular(path, args, cwd)
      {:error, message} -> {:error, message}
    end
  end

  defp resolve(command, finder) do
    cond do
      bare_name?(command) ->
        case finder.(command) do
          path when is_binary(path) -> {:ok, path}
          nil -> {:error, "could not find #{command}"}
        end

      host_absolute?(command) ->
        {:ok, command}

      true ->
        {:error, "#{command} is not an executable path on this host"}
    end
  end

  # This check follows the host. `AgentLink.Agent.Launch` accepts every
  # absolute form on every host. A foreign form must not reach `File.stat/1`.
  defp host_absolute?(command) do
    case :os.type() do
      {:win32, _} -> windows_absolute?(command)
      _ -> String.starts_with?(command, "/")
    end
  end

  # `:filename.win32_pathtype/1` treats two leading slashes as absolute.
  # Each slash may be `/` or `\`. One leading slash is not absolute.
  defp windows_absolute?(<<sep1, sep2, _rest::binary>>)
       when sep1 in [?/, ?\\] and sep2 in [?/, ?\\],
       do: true

  defp windows_absolute?(<<letter, ":", sep, _rest::binary>>)
       when (letter in ?A..?Z or letter in ?a..?z) and sep in [?/, ?\\],
       do: true

  defp windows_absolute?(_command), do: false

  defp bare_name?(command) do
    command not in [".", ".."] and
      not String.contains?(command, ["/", "\\"]) and
      not drive_relative?(command)
  end

  defp drive_relative?(<<letter, ":", _rest::binary>>)
       when letter in ?A..?Z or letter in ?a..?z,
       do: true

  defp drive_relative?(_command), do: false

  defp open_regular(path, args, cwd) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        spawn_executable(path, args, cwd)

      {:ok, %File.Stat{type: type}} ->
        {:error, "#{path} is a #{type}, not a regular file"}

      {:error, reason} ->
        {:error, "could not stat #{path}: #{inspect(reason)}"}
    end
  end

  defp spawn_executable(path, args, cwd) do
    {program, program_args, group?} = launch_program(path, args)

    port =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, program_args},
        {:cd, cwd},
        {:env, port_env()}
      ])

    store_record(port, group?)
    {:ok, port}
  rescue
    error in [ErlangError, ArgumentError] ->
      {:error, "could not open #{path}: #{inspect(open_reason(error))}"}
  end

  # erl_child_setup already makes the command a session leader. Wrapping it
  # in util-linux setsid forks again, because setsid() fails for a leader,
  # and the command leaves the pid this port owns. The group id is read from
  # /proc, so only Linux records one.
  defp launch_program(path, args) do
    if match?({:unix, :linux}, :os.type()), do: {path, args, true}, else: {path, args, false}
  end

  defp store_record(port, group?) do
    with {:os_pid, pid} <- Port.info(port, :os_pid),
         {:ok, identity} <- read_identity(pid) do
      Process.put(record_key(port), %Record{
        os_pid: pid,
        starttime: identity.starttime,
        group: group?
      })
    else
      _ -> :ok
    end
  end

  defp take_record(port), do: Process.delete(record_key(port))

  defp record_key(port), do: {__MODULE__, port}

  defp close_port(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  end

  defp stop_timeout do
    Application.get_env(:agent_link, :agent_stop_timeout, 5_000)
  end

  defp confirm_timeout(timeout), do: max(timeout, @stop_step_ms)

  defp signal_error(:ok), do: :ok
  defp signal_error({:error, reason}), do: {:error, reason}

  defp first_error(results) do
    Enum.find(results, :ok, &match?({:error, _}, &1))
  end

  defp snapshot(%Record{os_pid: pid, starttime: starttime, group: group?}) do
    case read_identity(pid) do
      {:ok, %Identity{starttime: ^starttime, pgrp: pgrp}} ->
        root = %Owned{pid: pid, starttime: starttime, pgrp: pgrp, root: true, group: group?}
        [root | descendants(pid)]

      _ ->
        []
    end
  end

  defp rescan(record, owned) do
    known = MapSet.new(owned, & &1.pid)
    owned ++ Enum.reject(snapshot(record), &MapSet.member?(known, &1.pid))
  end

  defp refresh(owned) do
    Enum.flat_map(owned, fn %Owned{pid: pid, starttime: starttime} = proc ->
      case read_identity(pid) do
        {:ok, %Identity{starttime: ^starttime, pgrp: pgrp}} -> [%{proc | pgrp: pgrp}]
        _ -> []
      end
    end)
  end

  defp retain_alive(owned) do
    identities =
      Enum.flat_map(owned, fn %Owned{pid: pid, starttime: starttime} ->
        if matching?(pid, starttime), do: [{pid, starttime}], else: []
      end)

    AgentLink.Agent.Reaper.retain(identities)
  end

  defp descendants(root_pid) do
    table = proc_table()

    walk(
      fn pid ->
        Enum.flat_map(table, fn {child, %Identity{ppid: ppid} = identity} ->
          if ppid == pid, do: [{child, identity}], else: []
        end)
      end,
      [root_pid],
      MapSet.new([root_pid]),
      []
    )
  end

  defp walk(_children, [], _seen, acc), do: acc

  defp walk(children, [pid | rest], seen, acc) do
    found =
      pid
      |> children.()
      |> Enum.reject(fn {child, _identity} -> MapSet.member?(seen, child) or child <= 1 end)

    seen = Enum.reduce(found, seen, fn {child, _identity}, set -> MapSet.put(set, child) end)

    owned =
      Enum.map(found, fn {child, identity} ->
        %Owned{
          pid: child,
          starttime: identity.starttime,
          pgrp: identity.pgrp,
          root: false,
          group: false
        }
      end)

    walk(children, rest ++ Enum.map(found, &elem(&1, 0)), seen, acc ++ owned)
  end

  defp proc_table do
    case File.ls("/proc") do
      {:ok, names} ->
        Enum.reduce(names, %{}, fn name, acc ->
          case Integer.parse(name) do
            {pid, ""} ->
              case read_identity(pid) do
                {:ok, identity} -> Map.put(acc, pid, identity)
                :error -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp signal_owned(owned, name) do
    root = Enum.find(owned, & &1.root)
    group? = group_signal?(root)

    results =
      if group? do
        [run_kill(name, -root.pid)]
      else
        []
      end

    results =
      results ++
        Enum.map(owned, fn proc ->
          cond do
            group? and in_group?(proc, root) -> :ok
            signalable?(proc) -> run_kill(name, proc.pid)
            true -> :ok
          end
        end)

    first_error(results)
  end

  defp group_signal?(%Owned{root: true, group: true, pid: pid, pgrp: pgrp} = proc) do
    pgrp == pid and signalable?(proc)
  end

  defp group_signal?(_proc), do: false

  defp in_group?(%Owned{pgrp: pgrp}, %Owned{pid: root_pid}), do: pgrp == root_pid

  defp signalable?(%Owned{pid: pid, starttime: starttime}) do
    pid > 1 and Integer.to_string(pid) != System.pid() and matching?(pid, starttime)
  end

  defp matching?(pid, starttime) do
    case read_identity(pid) do
      {:ok, %Identity{starttime: ^starttime}} -> true
      _ -> false
    end
  end

  # procps kill treats a negative pid as an option unless it follows `--`.
  # `-s TERM -- -123` signals process group 123. `-s TERM -- 123` signals
  # that pid. The shell builtin is not used: `System.cmd/3` does not run a shell.
  defp run_kill(name, target) do
    signal = if name == :kill, do: "KILL", else: "TERM"

    case System.find_executable("kill") do
      nil ->
        Logger.error("agent stop could not find kill")
        {:error, :no_kill}

      kill ->
        {output, status} =
          System.cmd(kill, ["-s", signal, "--", Integer.to_string(target)],
            stderr_to_stdout: true
          )

        cond do
          status == 0 ->
            :ok

          not kill_target_alive?(target) ->
            :ok

          true ->
            Logger.error("agent stop kill failed status=#{status} #{String.trim(output)}")
            {:error, :kill_failed}
        end
    end
  end

  defp kill_target_alive?(target) when is_integer(target) do
    pid = abs(target)
    pid > 1 and File.exists?("/proc/#{pid}")
  end

  defp wait_gone(owned, timeout) do
    poll_gone(owned, System.monotonic_time(:millisecond), timeout)
  end

  defp poll_gone(owned, started, timeout) do
    cond do
      Enum.all?(owned, &gone?/1) ->
        :gone

      System.monotonic_time(:millisecond) - started >= timeout ->
        :timeout

      true ->
        receive do
        after
          10 -> :ok
        end

        poll_gone(owned, started, timeout)
    end
  end

  defp gone?(%Owned{pid: pid, starttime: starttime}) do
    not matching?(pid, starttime)
  end

  defp read_identity(pid) when is_integer(pid) and pid > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> parse_stat(stat)
      _ -> :error
    end
  end

  defp read_identity(_pid), do: :error

  # `/proc/<pid>/stat` is `pid (comm) state ppid pgrp ... starttime`.
  # `comm` can contain spaces and parentheses. The last `)` ends it.
  # `ppid` is the second field after that. `pgrp` is the third.
  # `starttime` is the twentieth.
  defp parse_stat(stat) do
    case :binary.matches(stat, ")") do
      [] ->
        :error

      matches ->
        {pos, 1} = List.last(matches)
        rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
        fields = String.split(rest, " ", trim: true)

        with ppid when is_binary(ppid) <- Enum.at(fields, 1),
             pgrp when is_binary(pgrp) <- Enum.at(fields, 2),
             starttime when is_binary(starttime) <- Enum.at(fields, 19),
             {ppid, ""} <- Integer.parse(ppid),
             {pgrp, ""} <- Integer.parse(pgrp) do
          {:ok, %Identity{ppid: ppid, pgrp: pgrp, starttime: starttime}}
        else
          _ -> :error
        end
    end
  end

  defp open_reason(%ErlangError{original: reason}), do: reason
  defp open_reason(%ArgumentError{message: reason}), do: reason

  defp owner_error(owner, command) do
    "AgentLink.Agent.Process.open/3 must be called from the owner (#{inspect(owner)}) for #{command}"
  end
end
