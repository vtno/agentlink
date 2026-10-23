defmodule Pont.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    case Pont.Access.authenticate(conn) do
      {:ok, subject} ->
        runtimes = Pont.Registry.allowed(subject)

        body =
          Jason.encode!(%{
            "plane" => "127.0.0.1:#{Application.fetch_env!(:pont, :port)}",
            "runtimes" => runtimes
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      :reject ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  get "/acp" do
    case Pont.Access.authenticate(conn) do
      {:ok, subject} ->
        conn
        |> WebSockAdapter.upgrade(Pont.ClientSocket, subject, timeout: :infinity)
        |> halt()

      :reject ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  get "/agent" do
    case agent_subject(conn) do
      {:ok, subject} ->
        conn
        |> WebSockAdapter.upgrade(Pont.AgentSocket, subject, timeout: :infinity)
        |> halt()

      :reject ->
        Pont.Setup.rejected()
        send_resp(conn, 401, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp agent_subject(conn) do
    with true <- Pont.Auth.enabled?(),
         {:ok, subject} <- Pont.Access.authenticate(conn) do
      {:ok, subject}
    else
      _ -> :reject
    end
  end
end
