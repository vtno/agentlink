defmodule Pont.CLI do
  @moduledoc """
  The start command. No arguments runs the plane and the relay.
  `plane` is the plane alone. `relay` starts `Pont.Relay.Agent`.
  """

  defstruct mode: :all, port: nil, token: nil

  @doc "Read the command and store the mode, port, and token."
  def apply(argv \\ System.argv()) do
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
    pont [--port PORT] [--token TOKEN]
    pont plane [--port PORT] [--token TOKEN]
    pont relay --token TOKEN
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

  defp options(rest) do
    case OptionParser.parse(rest, strict: [port: :integer, token: :string]) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, usage()}
    end
  end

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

  defp store(%__MODULE__{mode: mode, port: port, token: token}) do
    Application.put_env(:pont, :mode, mode)

    if port do
      Application.put_env(:pont, :port, port)
      Application.put_env(:pont, :plane_url, Pont.Paths.plane_url(port))
    end
    if token, do: Application.put_env(:pont, :master_token, token)
    :ok
  end
end
