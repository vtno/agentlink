defmodule Pont.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    if Pont.Auth.allowed?(conn) do
      body =
        Jason.encode!(%{
          "plane" => "127.0.0.1:#{Application.fetch_env!(:pont, :port)}",
          "runtimes" => Pont.Registry.list()
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      send_resp(conn, 401, "unauthorized")
    end
  end

  get "/acp" do
    if Pont.Auth.allowed?(conn) do
      conn
      |> WebSockAdapter.upgrade(Pont.ClientSocket, [], timeout: :infinity)
      |> halt()
    else
      send_resp(conn, 401, "unauthorized")
    end
  end

  get "/agent" do
    if Pont.Auth.allowed?(conn) do
      conn
      |> WebSockAdapter.upgrade(Pont.AgentSocket, [], timeout: :infinity)
      |> halt()
    else
      send_resp(conn, 401, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
