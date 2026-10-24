defmodule Pont.CLI do
  @moduledoc """
  The start command. No arguments runs the plane and the agent relay.
  `plane` is the plane alone. `agent` is the relay alone.
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

  @doc "Turn argv into a command. `:help` prints usage and does not start."
  def parse([]), do: {:ok, %__MODULE__{}}
  def parse(["--help" | _]), do: {:ok, :help}
  def parse(["-h" | _]), do: {:ok, :help}
  def parse(["plane" | rest]), do: flags(rest, %__MODULE__{mode: :plane})
  def parse(["agent" | rest]), do: flags(rest, %__MODULE__{mode: :agent})
  def parse(["--" <> _ | _] = argv), do: flags(argv, %__MODULE__{})
  def parse(_argv), do: {:error, usage()}

  @doc "The commands this binary accepts."
  def usage do
    """
    pont [--port PORT] [--token TOKEN]
    pont plane [--port PORT] [--token TOKEN]
    pont agent --token TOKEN
    """
  end

  defp flags(rest, %__MODULE__{} = cli) do
    case OptionParser.parse(rest, strict: [port: :integer, token: :string]) do
      {opts, [], []} -> build(cli, opts)
      _ -> {:error, usage()}
    end
  end

  defp build(%__MODULE__{mode: :agent} = cli, opts) do
    cond do
      Keyword.has_key?(opts, :port) ->
        {:error, "pont agent does not listen.\n" <> usage()}

      opts[:token] in [nil, ""] ->
        {:error, "pont agent needs --token.\n" <> usage()}

      true ->
        {:ok, %{cli | token: opts[:token]}}
    end
  end

  defp build(%__MODULE__{} = cli, opts) do
    port = opts[:port]
    token = opts[:token]

    cond do
      token == "" ->
        {:error, usage()}

      port != nil and (port < 1 or port > 65_535) ->
        {:error, "port must be from 1 to 65535.\n" <> usage()}

      true ->
        {:ok, %{cli | port: port, token: token}}
    end
  end

  defp store(%__MODULE__{mode: mode, port: port, token: token}) do
    Application.put_env(:pont, :mode, mode)

    if port do
      Application.put_env(:pont, :port, port)
      Application.put_env(:pont, :plane_url, "ws://127.0.0.1:#{port}/agent")
    end

    if token, do: Application.put_env(:pont, :master_token, token)
    :ok
  end
end
