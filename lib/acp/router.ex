defmodule Acp.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    body =
      Jason.encode!(%{
        "plane" => "127.0.0.1:#{Application.fetch_env!(:acp, :port)}",
        "runtimes" => Acp.Registry.list()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/acp" do
    conn
    |> WebSockAdapter.upgrade(Acp.Socket, [], timeout: :infinity)
    |> halt()
  end

  get "/agent" do
    conn
    |> WebSockAdapter.upgrade(Acp.AgentSocket, [], timeout: :infinity)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
