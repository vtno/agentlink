defmodule Pont.Access.Single do
  @moduledoc """
  One operator. `--token` is the token. When it is unset, a plane mints one
  for this process and prints it. That admin owns every uplink and may use
  every uplink.
  """

  @behaviour Pont.Access

  @impl true
  def authenticate(conn) do
    if Pont.Auth.enabled?() and Pont.Auth.allowed?(conn) do
      {:ok, %Pont.Access.Subject{id: "admin", role: :admin}}
    else
      :reject
    end
  end

  @impl true
  def allowed?(%Pont.Access.Subject{role: :admin}, name) when is_binary(name), do: true
  def allowed?(%Pont.Access.Subject{}, name) when is_binary(name), do: false

  @impl true
  def claim(%Pont.Access.Subject{role: :admin}, name) when is_binary(name), do: :ok
  def claim(%Pont.Access.Subject{}, name) when is_binary(name), do: :reject

  @impl true
  def prepare(mode) do
    case ensure_token(mode) do
      {:existing, token} -> {:ok, message(mode, token, :given)}
      {:minted, token} -> {:ok, message(mode, token, :minted)}
      :missing -> {:error, "Pass --token. The plane prints it.\n"}
    end
  end

  @doc "The shell line that starts this binary as an agent relay."
  def command(token) when is_binary(token) do
    "pont agent --token '#{String.replace(token, "'", "'\\''")}'"
  end

  defp ensure_token(mode) do
    case configured_token() do
      token when is_binary(token) ->
        {:existing, token}

      _ when mode in [:plane, :all] ->
        token = mint()
        Application.put_env(:pont, :master_token, token)
        {:minted, token}

      _ ->
        :missing
    end
  end

  defp message(mode, token, source) do
    url = Application.get_env(:pont, :plane_url) || "ws://127.0.0.1:8090/agent"

    origin =
      case source do
        :minted ->
          "Pont created a token for this process. Pass the same --token to start again."

        :given ->
          "Pont is using the token from --token."
      end

    case mode do
      :plane ->
        """
        #{origin}
        Run this on the machine that should host the agent:

        #{command(token)}

        The plane listens on 127.0.0.1. On that machine, set plane_url in the link file to an address it can reach. This plane is #{url} when it is this machine.
        Waiting for the uplink to connect.
        """

      :all ->
        """
        #{origin}
        #{token}

        The agent relay on this machine is starting.
        Another machine can dial with:

        #{command(token)}
        """

      :agent ->
        "#{origin}\nThe uplink will dial the plane_url in the link file.\n"
    end
  end

  defp configured_token, do: Pont.Auth.token()

  defp mint do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
