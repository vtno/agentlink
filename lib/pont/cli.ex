defmodule Pont.CLI do
  @moduledoc """
  The start command. No arguments runs the plane and the relay.
  `plane` is the plane alone. `relay` starts `Pont.Relay.Agent`.
  """

  defstruct mode: :all, port: nil, token: nil, opencode_bin: nil

  @doc "Read the command and store the mode, port, token, and OpenCode executable."
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
  def parse(["--" <> _ | _] = argv), do: listen(argv, :all)
  def parse(_argv), do: {:error, usage()}

  @doc "The commands this binary accepts."
  def usage do
    """
    pont [--port PORT] [--token TOKEN] [--opencode-bin PATH]
    pont plane [--port PORT] [--token TOKEN]
    pont relay --token TOKEN [--opencode-bin PATH]
    """
  end

  defp listen(rest, mode) do
    with {:ok, opts} <- options(rest),
         :ok <- plane_bin(mode, opts),
         {:ok, port} <- optional_port(opts[:port]),
         {:ok, token} <- optional_token(opts[:token]),
         {:ok, bin} <- optional_bin(opts[:opencode_bin]) do
      {:ok, %__MODULE__{mode: mode, port: port, token: token, opencode_bin: bin}}
    end
  end

  defp relay(rest) do
    with {:ok, opts} <- options(rest),
         :ok <- no_port(opts),
         {:ok, token} <- required_token(opts[:token]),
         {:ok, bin} <- optional_bin(opts[:opencode_bin]) do
      {:ok, %__MODULE__{mode: :relay, token: token, opencode_bin: bin}}
    end
  end

  defp options(rest) do
    case OptionParser.parse(rest, strict: [port: :integer, token: :string, opencode_bin: :string]) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, usage()}
    end
  end

  defp plane_bin(:plane, opts) do
    if Keyword.has_key?(opts, :opencode_bin),
      do: {:error, "pont plane does not run opencode.\n" <> usage()},
      else: :ok
  end

  defp plane_bin(_mode, _opts), do: :ok

  defp no_port(opts) do
    if Keyword.has_key?(opts, :port),
      do: {:error, "pont relay does not listen.\n" <> usage()},
      else: :ok
  end

  defp required_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp required_token(_), do: {:error, "pont relay needs --token.\n" <> usage()}

  defp optional_token(nil), do: {:ok, nil}
  defp optional_token(""), do: {:error, usage()}
  defp optional_token(token) when is_binary(token), do: {:ok, token}

  defp optional_port(nil), do: {:ok, nil}

  defp optional_port(port) when is_integer(port) and port >= 1 and port <= 65_535, do: {:ok, port}

  defp optional_port(_port), do: {:error, "port must be from 1 to 65535.\n" <> usage()}

  defp optional_bin(nil), do: {:ok, nil}
  defp optional_bin(""), do: {:error, usage()}

  defp optional_bin(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded),
      do: {:ok, expanded},
      else: {:error, "opencode bin not found: #{expanded}\n" <> usage()}
  end

  defp store(%__MODULE__{mode: mode, port: port, token: token, opencode_bin: opencode_bin}) do
    Application.put_env(:pont, :mode, mode)

    if port do
      Application.put_env(:pont, :port, port)
      Application.put_env(:pont, :plane_url, Pont.Paths.plane_url(port))
    end

    if token, do: Application.put_env(:pont, :master_token, token)
    if opencode_bin, do: Application.put_env(:pont, :opencode_bin, opencode_bin)
    :ok
  end
end
