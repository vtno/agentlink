defmodule AgentLink.Agent.Process do
  @moduledoc """
  Open an `AgentLink.Agent.Launch` from the caller.

  `open/3`, `write/2`, and `close/1` run in the caller. This module does not
  start a GenServer. The relay does not call it. `AgentLink.OpenCode` is
  still the production behaviour. The handle is the port. This module does
  not read the link file, does not call `AgentLink.Agent.Launch.load/1`, and
  does not read application config.
  """

  alias AgentLink.Agent.Launch

  @doc """
  Open `launch` in `cwd`. The caller must be `owner`.

  Returns `{:ok, port}` or `{:error, message}`. Stdout arrives at the caller
  as `{port, {:data, binary}}`.

  When the caller is not `owner`, the error names `owner` and the command.
  That call does not use the finder and does not spawn.

  A bare name contains neither `/` nor `\\` and is not `.`, `..`, or a
  drive-relative form such as `C:opencode`. A bare name is passed to the
  finder. The fourth argument defaults to `&System.find_executable/1`.
  `open/3` is that call. `open/4` takes a finder so a test can pass a
  function. `nil` from the finder is an error that names the command.

  A path that is absolute on this host is used unchanged. It is not passed
  to the finder. It is not expanded against `cwd` or the VM cwd. On Unix, a
  host-absolute path starts with `/`. On Windows, `:os.type/0` returns
  `{:win32, _}` and a host-absolute path is a UNC path that starts with
  `\\\\`, or a drive letter, a colon, and a slash. That slash may be `/` or
  `\\`. `AgentLink.Agent.Launch` accepts a POSIX path, a UNC path, and a
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
  """
  @spec open(pid, Launch.t(), String.t(), (String.t() -> String.t() | nil)) ::
          {:ok, port} | {:error, String.t()}
  def open(owner, %Launch{command: command, args: args}, cwd, finder \\ &System.find_executable/1)
      when is_pid(owner) do
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
  Close `port` when it is open.

  Returns `:ok`. A second call also returns `:ok`. `close/1` closes the
  port, which closes the child's stdin. The fixture writes `eof` and
  halts. `close/1` does not reap a process tree. The fixture starts no
  child process.
  """
  @spec close(term) :: :ok
  def close(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
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

  defp windows_absolute?(<<"\\\\", _rest::binary>>), do: true

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
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, args},
        {:cd, cwd}
      ])

    {:ok, port}
  rescue
    error in [ErlangError, ArgumentError] ->
      {:error, "could not open #{path}: #{inspect(open_reason(error))}"}
  end

  defp open_reason(%ErlangError{original: reason}), do: reason
  defp open_reason(%ArgumentError{message: reason}), do: reason

  defp owner_error(owner, command) do
    "AgentLink.Agent.Process.open/3 must be called from the owner (#{inspect(owner)}) for #{command}"
  end
end
