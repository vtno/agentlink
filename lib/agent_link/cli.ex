defmodule AgentLink.CLI do
  @moduledoc """
  The start command. No arguments runs the plane and the relay.
  `plane` is the plane alone. `relay` starts `AgentLink.Relay.Agent`.
  `connect` starts `AgentLink.Relay.Client`.
  """

  defstruct mode: :all, port: nil, token: nil, plane: nil, target: nil

  @doc "Read the command and store the mode, the port, and the token."
  def apply(argv \\ nil) do
    argv = argv || argv_from_launch()

    case parse(argv) do
      {:ok, :help} ->
        IO.puts(usage())
        {:halt, 0}

      {:ok, %__MODULE__{} = cli} ->
        store(cli)
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        {:error, message}
    end
  end

  @doc "Arguments from the wrapped binary, or from the normal Elixir launch."
  def argv_from_launch(argv \\ nil) do
    argv =
      cond do
        is_list(argv) ->
          argv

        System.get_env("__BURRITO") != nil ->
          :init.get_plain_arguments() |> Enum.map(&to_string/1)

        true ->
          System.argv()
      end

    if System.get_env("__BURRITO") != nil, do: drop_launcher_prefix(argv), else: argv
  end

  @doc "Drop the `--no-halt --` pair the Burrito launcher inserts."
  def drop_launcher_prefix(["--no-halt", "--" | rest]), do: rest
  def drop_launcher_prefix(args), do: args

  @doc "Turn argv into a command. `:help` means show usage and do not start."
  def parse([]), do: {:ok, %__MODULE__{}}
  def parse(["--help" | _]), do: {:ok, :help}
  def parse(["-h" | _]), do: {:ok, :help}
  def parse(["plane" | rest]), do: listen(rest, :plane)
  def parse(["relay" | rest]), do: relay(rest)
  def parse(["connect" | rest]), do: connect(rest)
  def parse(["--" <> _ | _] = argv), do: listen(argv, :all)
  def parse(_argv), do: {:error, usage()}

  @doc "The commands this binary accepts."
  def usage do
    """
    agentlink [--port PORT] [--token TOKEN]
    agentlink plane [--port PORT] [--token TOKEN]
    agentlink relay --token TOKEN
    agentlink connect [--plane URL] [--target NAME] [--token TOKEN]
    """
  end

  defp listen(rest, mode) do
    with {:ok, opts} <- options(rest),
         {:ok, port} <- optional_port(opts[:port]),
         {:ok, token} <- optional_token(opts[:token]) do
      {:ok, %__MODULE__{mode: mode, port: port, token: token}}
    end
  end

  defp relay(rest) do
    with {:ok, opts} <- options(rest),
         :ok <- no_port(opts),
         {:ok, token} <- required_token(opts[:token]) do
      {:ok, %__MODULE__{mode: :relay, token: token}}
    end
  end

  defp connect(rest) do
    with {:ok, opts} <- connect_options(rest),
         {:ok, plane} <- optional_text(opts[:plane]),
         {:ok, target} <- optional_text(opts[:target]),
         {:ok, token} <- optional_text(opts[:token]) do
      {:ok, %__MODULE__{mode: :connect, plane: plane, target: target, token: token}}
    end
  end

  defp options(rest) do
    strict_options(rest, port: :integer, token: :string)
  end

  defp connect_options(rest) do
    strict_options(rest, plane: :string, target: :string, token: :string)
  end

  defp strict_options(rest, strict) do
    case OptionParser.parse(rest, strict: strict) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, usage()}
    end
  end

  defp no_port(opts) do
    if Keyword.has_key?(opts, :port),
      do: {:error, "agentlink relay does not listen.\n" <> usage()},
      else: :ok
  end

  defp required_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp required_token(_), do: {:error, "agentlink relay needs --token.\n" <> usage()}

  defp optional_token(token), do: optional_text(token)

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(""), do: {:error, usage()}
  defp optional_text(text) when is_binary(text), do: {:ok, text}

  defp optional_port(nil), do: {:ok, nil}

  defp optional_port(port) when is_integer(port) and port >= 1 and port <= 65_535, do: {:ok, port}

  defp optional_port(_port), do: {:error, "port must be from 1 to 65535.\n" <> usage()}

  defp store(%__MODULE__{mode: :connect, plane: plane, target: target, token: token}) do
    Application.put_env(:agent_link, :mode, :connect)
    Application.put_env(:agent_link, :connect_plane, plane)
    Application.put_env(:agent_link, :connect_target, target)
    Application.put_env(:agent_link, :connect_token, token)
    :ok
  end

  defp store(%__MODULE__{mode: mode, port: port, token: token}) do
    Application.put_env(:agent_link, :mode, mode)

    if port do
      Application.put_env(:agent_link, :port, port)
      Application.put_env(:agent_link, :plane_url, AgentLink.Paths.plane_url(port))
    end

    if token, do: Application.put_env(:agent_link, :master_token, token)
    :ok
  end
end
