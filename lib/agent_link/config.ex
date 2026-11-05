defmodule AgentLink.Config do
  @moduledoc """
  The plane URL, the optional target, and the token. `load/1` reads them.
  The CLI does not call `load/1` yet.
  """

  # Subsets of 0600. Any other permission bit is too open.
  @token_modes [0o600, 0o400, 0o200, 0o000]

  @type t :: %__MODULE__{
          plane: String.t() | nil,
          target: String.t() | nil,
          token: String.t() | nil
        }

  defstruct [:plane, :target, :token]

  @doc """
  Read the plane URL, the optional target, and the token.

  Each field comes from the first place that sets it. A `:plane`, `:target`,
  or `:token` option wins. Then `AGENTLINK_PLANE`, `AGENTLINK_TARGET`, and
  `AGENTLINK_TOKEN` in `:env`. Then the files under `:root`.

  `:root` defaults to `AgentLink.Paths.root/0`. `:env` defaults to
  `System.get_env/0`. `:root` must be a binary. `:env` must be a map.
  `:plane`, `:target`, and `:token` must be binaries or nil. A bad value
  raises `ArgumentError`. A nil value, and a binary that is empty after
  trimming, are unset. Stored values are trimmed.

  The config file is `config` under `:root`. For the default root, that path
  is `AgentLink.Paths.config/0`. The file is a JSON object. `plane` and
  `target` are optional strings. Other keys are ignored. A `token` key is an
  error, and the error names the token file. A missing file leaves `plane`
  and `target` unset. A file that is not a JSON object is an error.

  The token file is `token` under `:root`. For the default root, that path is
  `AgentLink.Paths.token/0`. `load/1` reads it only when the token is still
  unset. The file must be a regular file in mode 0600, 0400, 0200, or 0000.
  A missing file leaves `token` unset.
  """
  @spec load(keyword) :: {:ok, t} | {:error, String.t()}
  def load(opts) when is_list(opts) do
    root = root!(opts)
    env = env!(opts)
    config_path = child(root, &AgentLink.Paths.config/0)
    token_path = child(root, &AgentLink.Paths.token/0)

    with {:ok, plane} <- field(opts, :plane, env, "AGENTLINK_PLANE"),
         {:ok, target} <- field(opts, :target, env, "AGENTLINK_TARGET"),
         {:ok, token} <- field(opts, :token, env, "AGENTLINK_TOKEN"),
         {:ok, file} <- read_config(config_path, token_path),
         {:ok, token} <- resolve_token(token, token_path) do
      {:ok, %__MODULE__{plane: plane || file.plane, target: target || file.target, token: token}}
    end
  end

  defp root!(opts) do
    case Keyword.get(opts, :root, AgentLink.Paths.root()) do
      root when is_binary(root) ->
        root

      other ->
        raise ArgumentError, ":root must be a binary, got: #{inspect(other)}"
    end
  end

  defp env!(opts) do
    case Keyword.get(opts, :env, System.get_env()) do
      env when is_map(env) ->
        env

      other ->
        raise ArgumentError, ":env must be a map, got: #{inspect(other)}"
    end
  end

  defp child(root, path_fun) do
    Path.join(root, Path.basename(path_fun.()))
  end

  defp field(opts, key, env, env_key) do
    case take(Keyword.get(opts, key), key) do
      {:ok, nil} -> take(Map.get(env, env_key), env_key)
      {:ok, _value} = ok -> ok
    end
  end

  defp take(nil, _name), do: {:ok, nil}

  defp take(value, name) when is_binary(value) do
    if String.valid?(value) do
      {:ok, trim(value)}
    else
      raise ArgumentError, "#{label(name)} must be valid UTF-8"
    end
  end

  defp take(value, name) do
    raise ArgumentError, "#{label(name)} must be a binary, got: #{inspect(value)}"
  end

  defp label(name) when is_atom(name), do: inspect(name)
  defp label(name) when is_binary(name), do: name

  defp trim(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp read_config(path, token_path) do
    case File.read(path) do
      {:ok, body} -> decode_config(path, token_path, body)
      {:error, :enoent} -> {:ok, %{plane: nil, target: nil}}
      {:error, reason} -> {:error, read_error(path, reason)}
    end
  end

  defp decode_config(path, token_path, body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> config_map(path, token_path, map)
      _ -> {:error, "#{path} is not a JSON object.\n"}
    end
  end

  defp config_map(path, token_path, map) do
    if Map.has_key?(map, "token") do
      {:error, "#{path} must not contain a token. Put the token in #{token_path}.\n"}
    else
      with {:ok, plane} <- json_string(path, map, "plane"),
           {:ok, target} <- json_string(path, map, "target") do
        {:ok, %{plane: plane, target: target}}
      end
    end
  end

  defp json_string(path, map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        take(value, key)

      {:ok, _value} ->
        {:error, "#{path} #{key} must be a string.\n"}
    end
  end

  defp resolve_token(token, _path) when is_binary(token), do: {:ok, token}
  defp resolve_token(nil, path), do: read_token(path)

  defp read_token(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        bits = Bitwise.band(mode, 0o7777)

        if bits in @token_modes do
          read_token_body(path)
        else
          {:error, mode_error(path, bits)}
        end

      {:ok, %File.Stat{}} ->
        {:error, "#{path} must be a regular file.\n"}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, read_error(path, reason)}
    end
  end

  defp read_token_body(path) do
    case File.read(path) do
      {:ok, body} ->
        if String.valid?(body) do
          {:ok, trim(body)}
        else
          {:error, "#{path} is not valid UTF-8.\n"}
        end

      {:error, reason} ->
        {:error, read_error(path, reason)}
    end
  end

  defp mode_error(path, bits) do
    mode = bits |> Integer.to_string(8) |> String.pad_leading(4, "0")
    "#{path} is mode #{mode}. It must be 0600 or tighter.\n"
  end

  defp read_error(path, reason), do: "Could not read #{path}: #{inspect(reason)}\n"
end
