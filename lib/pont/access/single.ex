defmodule Pont.Access.Single do
  @moduledoc """
  One operator. `PONT_MASTER_TOKEN` is the token. When it is unset, a plane
  mints one for this process and prints it. That admin owns every uplink and may
  use every uplink.
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
      {:existing, token} -> {:ok, message(mode, token, :env)}
      {:minted, token} -> {:ok, message(mode, token, :minted)}
      :missing -> {:error, "PONT_MASTER_TOKEN is not set.\n"}
    end
  end

  @doc "The shell line that starts an agent relay against this plane."
  def command(token, url) when is_binary(token) and is_binary(url) do
    "PONT_MODE=agent PONT_MASTER_TOKEN='#{token}' PONT_PLANE_URL='#{url}' mix run --no-halt"
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
          "Pont created a master token for this process. Set PONT_MASTER_TOKEN to this value to keep it."

        :env ->
          "Pont is using PONT_MASTER_TOKEN."
      end

    case mode do
      :plane ->
        """
        #{origin}
        Run this on the machine that should host the agent:

        #{command(token, url)}

        The plane listens on 127.0.0.1. If that machine is not this one, set PONT_PLANE_URL to an address it can reach.
        Waiting for the agent relay to connect.
        """

      :all ->
        """
        #{origin}
        #{token}

        The agent relay on this machine is starting.
        Another machine can dial with:

        #{command(token, url)}
        """

      :agent ->
        "#{origin}\nThe agent relay will dial #{url}.\n"
    end
  end

  defp configured_token, do: Pont.Auth.token()

  defp mint do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
