defmodule AgentLink.Agent.Launch do
  @moduledoc """
  Raw `command` and `args` from the link file.

  `load/1` reads that file once. It returns the `AgentLink.Link` built from
  the decoded object and an `AgentLink.Agent.Launch`. Production startup
  calls `AgentLink.Link.read/1` and does not call `load/1`. The relay still
  opens `AgentLink.OpenCode`.

  `load/1` does not look up an executable and does not start a process.
  """

  @type t :: %__MODULE__{command: String.t(), args: [String.t()]}

  defstruct [:command, :args]

  @doc """
  Read the link file at `path` and return the link and the launch data.

  `path` defaults to nil. Nil uses `AgentLink.Link.path/0`. Each call reads
  that path again. A rewrite is visible on the next call.

  The link matches `AgentLink.Link.read/1` for the same file. A missing
  file, a file that cannot be read, and a file that is not a JSON object
  return that same error.

  An `env` key is an error. The error does not include the value. `load/1`
  checks that key before `command` and `args`. Any value is rejected,
  including null.

  `command` is required. It must be a string. `load/1` trims it and stores
  the trimmed string. A blank command is an error. A relative command is an
  error. `.` and `..` are relative. `./opencode`, `bin/kimi`, `.\\opencode`,
  `bin\\kimi`, and a drive-relative form such as `C:opencode` are relative.

  A command is absolute when it starts with `/`, when it starts with `\\`,
  or when it starts with a drive letter, a colon, and a slash. The slash
  may be `/` or `\\`. Those are the absolute forms for the Linux, macOS,
  and Windows targets this project builds. A bare name contains neither
  `/` nor `\\`, and it is not a drive-relative form. `load/1` keeps an
  absolute path or a bare name. It does not search `PATH`, and it does not
  require the path to name a file that exists.

  `args` is required. It must be a list of strings. `[]` is valid. Each
  string is stored as written.

  Any other unknown key is ignored. `program` keeps the default from
  `AgentLink.Link.read/1`.
  """
  @spec load(String.t() | nil) :: {:ok, AgentLink.Link.t(), t()} | {:error, String.t()}
  def load(path \\ nil) do
    path = path || AgentLink.Link.path()

    with {:ok, link, object} <- AgentLink.Link.read_object(path),
         {:ok, launch} <- from_object(object, path) do
      {:ok, link, launch}
    end
  end

  defp from_object(object, path) do
    with :ok <- reject_env(object, path),
         {:ok, command} <- command(object, path),
         {:ok, args} <- args(object, path) do
      {:ok, %__MODULE__{command: command, args: args}}
    end
  end

  defp reject_env(object, path) do
    if Map.has_key?(object, "env") do
      {:error, "#{path} must not contain env.\n"}
    else
      :ok
    end
  end

  defp command(object, path) do
    case Map.fetch(object, "command") do
      :error ->
        {:error, "#{path} must include a command.\n"}

      {:ok, value} when is_binary(value) ->
        command_text(path, String.trim(value))

      {:ok, _value} ->
        {:error, "#{path} command must be a string.\n"}
    end
  end

  defp command_text(path, text) do
    cond do
      text == "" ->
        {:error, "#{path} command must not be blank.\n"}

      absolute?(text) or bare?(text) ->
        {:ok, text}

      true ->
        {:error, "#{path} command must be an absolute path or a bare name.\n"}
    end
  end

  # Linux, macOS, and Windows share this check. `Path.type/1` follows the host OS.
  defp absolute?(<<letter, ":", sep, _rest::binary>>)
       when (letter in ?A..?Z or letter in ?a..?z) and sep in [?/, ?\\] do
    true
  end

  defp absolute?(<<"/", _rest::binary>>), do: true
  defp absolute?(<<"\\", _rest::binary>>), do: true
  defp absolute?(_text), do: false

  defp bare?(text) do
    text not in [".", ".."] and
      not String.contains?(text, ["/", "\\"]) and
      not volume_relative?(text)
  end

  defp volume_relative?(<<letter, ":", _rest::binary>>)
       when letter in ?A..?Z or letter in ?a..?z do
    true
  end

  defp volume_relative?(_text), do: false

  defp args(object, path) do
    case Map.fetch(object, "args") do
      :error ->
        {:error, "#{path} must include args.\n"}

      {:ok, args} when is_list(args) ->
        if Enum.all?(args, &is_binary/1) do
          {:ok, args}
        else
          {:error, "#{path} args must be a list of strings.\n"}
        end

      {:ok, _args} ->
        {:error, "#{path} args must be a list of strings.\n"}
    end
  end
end
