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

  defmodule Record do
    @moduledoc false
    defstruct [:os_pid, :starttime, :group]
  end

  defmodule Identity do
    @moduledoc false
    defstruct [:pgrp, :starttime]
  end

  @doc """
  Open `launch` in `cwd`. The caller must be `owner`.

  Returns `{:ok, port}` or `{:error, message}`. Stdout arrives at the caller
  as `{port, {:data, binary}}`.

  When the caller is not `owner`, the error names `owner` and the command.
  That call does not use the finder and does not spawn.

  A bare name contains neither `/` nor `\\` and is not `.`, `..`, or a
  drive-relative form such as `C:opencode`. A bare name is passed to the
  finder. `open/3` calls `open/4` with `&System.find_executable/1`.
  `open/4` takes a finder so a test can pass a function. `nil` from the
  finder is an error that names the command.

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
  is omitted, so the port inherits the VM environment. `:stderr_to_stdout`
  is omitted. `ErlangError` and `ArgumentError` from `Port.open/2` are
  returned as an error that names the path and the reason from the spawn.
  The OS decides that reason.

  On Linux the VM's port spawn makes the command a session leader. That pid
  is the process group leader. Descendants stay in that group until one of
  them starts its own session. `close/1` signals the group when
  `/proc/<pid>/stat` still has the same start time and the process group id
  is still that pid. On macOS and Windows, `close/1` closes stdin and does
  not signal a process group. It does not create a Windows Job Object.
  """
  @impl true
  @spec open(pid, Launch.t(), String.t()) :: {:ok, port} | {:error, String.t()}
  def open(owner, %Launch{} = launch, cwd) when is_pid(owner) do
    open(owner, launch, cwd, &System.find_executable/1)
  end

  @doc """
  Open `launch` in `cwd` with `finder`. The caller must be `owner`.

  `open/3` is the `AgentLink.Agent` callback. `open/4` is not.
  """
  @spec open(pid, Launch.t(), String.t(), (String.t() -> String.t() | nil)) ::
          {:ok, port} | {:error, String.t()}
  def open(owner, %Launch{command: command, args: args}, cwd, finder)
      when is_pid(owner) and is_function(finder, 1) do
    if owner == self() do
      open_command(command, args, cwd, finder)
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

  Returns `:ok`. A second call also returns `:ok`.

  When `open/3` recorded an OS pid, `close/1` signals that process only when
  `/proc/<pid>/stat` still has the same start time. On Linux, a process group
  leader is signaled with the group id, which is the negative pid. Any other
  recorded pid is signaled alone. The signal is `SIGTERM`. `close/1` then
  closes the port, which closes the child's stdin, and waits until the start
  time no longer matches.

  The wait is `:agent_stop_timeout` milliseconds. `Application.get_env/3`
  reads `:agent_link, :agent_stop_timeout`. The default is `5000`. When the
  start time still matches at the deadline, `close/1` signals `SIGKILL` the
  same way and waits again for the same number of milliseconds.
  `AgentLink.Relay.Agent` gives this call that long, twice, plus one second,
  before the supervisor kills the relay.

  A pid whose start time changed is left alone. `close/1` does not signal
  the VM's own OS pid. On macOS and Windows, `close/1` closes stdin and does
  not signal a process group. It does not create a Windows Job Object.
  """
  @impl true
  @spec close(term) :: :ok
  def close(port) do
    case take_record(port) do
      nil ->
        close_port(port)

      record ->
        signal(record, :term)
        close_port(port)
        timeout = stop_timeout()

        if wait_gone(record, timeout) == :timeout do
          signal(record, :kill)
          wait_gone(record, timeout)
        end
    end

    :ok
  end

  defp open_command(command, args, cwd, finder) do
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
        {:cd, cwd}
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

  defp signal(%Record{os_pid: pid, starttime: starttime, group: group?}, name) do
    with true <- is_integer(pid) and pid > 1,
         true <- Integer.to_string(pid) != System.pid(),
         {:ok, %Identity{starttime: ^starttime} = identity} <- read_identity(pid) do
      target = if group? and identity.pgrp == pid, do: -pid, else: pid
      run_kill(name, target)
    else
      _ -> :ok
    end
  end

  # procps kill treats a negative pid as an option unless it follows `--`.
  # `-s TERM -- -123` signals process group 123. `-s TERM -- 123` signals
  # that pid. The shell builtin is not used: `System.cmd/3` does not run a shell.
  defp run_kill(name, target) do
    signal = if name == :kill, do: "KILL", else: "TERM"

    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        System.cmd(kill, ["-s", signal, "--", Integer.to_string(target)], stderr_to_stdout: true)
        :ok
    end
  end

  defp wait_gone(record, timeout) do
    poll_gone(record, System.monotonic_time(:millisecond), timeout)
  end

  defp poll_gone(record, started, timeout) do
    cond do
      gone?(record) ->
        :gone

      System.monotonic_time(:millisecond) - started >= timeout ->
        :timeout

      true ->
        receive do
        after
          10 -> :ok
        end

        poll_gone(record, started, timeout)
    end
  end

  defp gone?(%Record{os_pid: pid, starttime: starttime}) do
    case read_identity(pid) do
      {:ok, %Identity{starttime: ^starttime}} -> false
      _ -> true
    end
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
  # `pgrp` is the third field after that. `starttime` is the twentieth.
  defp parse_stat(stat) do
    case :binary.matches(stat, ")") do
      [] ->
        :error

      matches ->
        {pos, 1} = List.last(matches)
        rest = binary_part(stat, pos + 2, byte_size(stat) - pos - 2)
        fields = String.split(rest, " ", trim: true)

        with pgrp when is_binary(pgrp) <- Enum.at(fields, 2),
             starttime when is_binary(starttime) <- Enum.at(fields, 19),
             {pgrp, ""} <- Integer.parse(pgrp) do
          {:ok, %Identity{pgrp: pgrp, starttime: starttime}}
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
