defmodule Pont.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    open(conn, fn conn, subject ->
      body =
        Jason.encode!(%{
          "plane" => "127.0.0.1:#{Application.fetch_env!(:pont, :port)}",
          "runtimes" => Pont.Registry.allowed(subject)
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end)
  end

  get "/acp" do
    open(conn, fn conn, subject ->
      conn
      |> WebSockAdapter.upgrade(Pont.ClientSocket, subject, timeout: :infinity)
      |> halt()
    end)
  end

  get "/agent" do
    case Pont.Access.agent_relay(conn) do
      {:ok, subject} ->
        conn
        |> WebSockAdapter.upgrade(Pont.AgentSocket, subject, timeout: :infinity)
        |> halt()

      {:reject, reason} ->
        Pont.Setup.Watch.rejected(reason)
        send_resp(conn, 401, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp open(conn, fun) do
    case Pont.Access.authenticate(conn) do
      {:ok, subject} -> fun.(conn, subject)
      :reject -> send_resp(conn, 401, "unauthorized")
    end
  end
end
