defmodule AgentLink.Router do
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
          "plane" => "127.0.0.1:#{Application.fetch_env!(:agent_link, :port)}",
          "runtimes" => AgentLink.Registry.allowed(subject)
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end)
  end

  get "/acp" do
    open(conn, fn conn, subject ->
      conn
      |> WebSockAdapter.upgrade(AgentLink.ClientSocket, subject, timeout: :infinity)
      |> halt()
    end)
  end

  get "/agent" do
    case AgentLink.Access.agent_caller(conn) do
      {:ok, subject} ->
        conn
        |> WebSockAdapter.upgrade(AgentLink.AgentSocket, subject, timeout: :infinity)
        |> halt()

      {:reject, reason} ->
        AgentLink.Setup.Watch.rejected(reason)
        send_resp(conn, 401, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp open(conn, fun) do
    case AgentLink.Access.authenticate(conn) do
      {:ok, subject} -> fun.(conn, subject)
      :reject -> send_resp(conn, 401, "unauthorized")
    end
  end
end
