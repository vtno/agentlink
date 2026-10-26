defmodule Pont.Auth do
  @moduledoc """
  One shared bearer token for the plane. Callers send `Authorization: Bearer`,
  or `?token=` when the client cannot set a header. The helpers here treat an
  unset token as open: `allowed?/1` is true when no token is configured. The
  access policy is stricter: it rejects a connection when no token is set,
  so `/acp`, `/agent`, and `/status` all require the token.
  """

  @doc "The configured master token, or nil when it is unset."
  def token do
    case Application.get_env(:pont, :master_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc "True when a token is set."
  def enabled?, do: is_binary(token())

  @doc "True when auth is off, or the request presents the configured token."
  def allowed?(conn) do
    case token() do
      expected when is_binary(expected) -> same_token?(presented(conn), expected)
      _ -> true
    end
  end

  @doc "Header the uplink sends. Empty when auth is off."
  def headers do
    case token() do
      token when is_binary(token) -> [{"authorization", "Bearer " <> token}]
      _ -> []
    end
  end

  defp presented(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params["token"] do
      token when is_binary(token) and token != "" -> token
      _ -> bearer(Plug.Conn.get_req_header(conn, "authorization"))
    end
  end

  defp bearer(["Bearer " <> token | _]) when token != "", do: token
  defp bearer(["bearer " <> token | _]) when token != "", do: token
  defp bearer(_), do: nil

  defp same_token?(presented, expected) when is_binary(presented) do
    byte_size(presented) == byte_size(expected) and Plug.Crypto.secure_compare(presented, expected)
  end

  defp same_token?(_, _), do: false
end
