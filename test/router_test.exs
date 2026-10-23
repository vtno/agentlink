defmodule Pont.RouterTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:pont, :master_token)
    start_supervised!(Pont.Registry)
    start_supervised!(Pont.Plane)
    start_supervised!({Bandit, plug: Pont.Router, scheme: :http, port: 18_091, ip: {127, 0, 0, 1}})

    on_exit(fn ->
      if previous, do: Application.put_env(:pont, :master_token, previous), else: Application.delete_env(:pont, :master_token)
    end)

    :ok
  end

  test "health, status, and an unknown path" do
    Application.put_env(:pont, :master_token, "sekret")

    assert request("GET", "/health") == {200, "ok"}
    {200, body} = request("GET", "/status", [{"authorization", "Bearer sekret"}])
    decoded = Jason.decode!(body)
    assert decoded["plane"] == "127.0.0.1:#{Application.fetch_env!(:pont, :port)}"
    assert decoded["runtimes"] == []
    assert {404, "not found"} = request("GET", "/nope")
  end

  test "the app and agent paths upgrade to a websocket" do
    Application.put_env(:pont, :master_token, "sekret")
    assert {:ok, conn, _ref, _ws} = upgrade("/acp?token=sekret")
    Mint.HTTP.close(conn)

    previous = Application.get_env(:pont, :master_token)
    Application.put_env(:pont, :master_token, "sekret")

    on_exit(fn ->
      if previous, do: Application.put_env(:pont, :master_token, previous), else: Application.delete_env(:pont, :master_token)
    end)

    assert {:ok, conn, ref, websocket} = upgrade("/agent", [{"authorization", "Bearer sekret"}])
    hello = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "pont.uplink", "params" => %{"name" => "lab", "label" => "Bench"}})
    {:ok, _websocket, data} = Mint.WebSocket.encode(websocket, {:text, hello})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, _conn} = Mint.HTTP.set_mode(conn, :active)
    Process.sleep(100)
    assert Pont.Registry.pid("lab")
    Mint.HTTP.close(conn)
  end

  test "a token guards status and both sockets, and health stays open" do
    previous = Application.get_env(:pont, :master_token)
    Application.put_env(:pont, :master_token, "sekret")
    on_exit(fn ->
      if previous, do: Application.put_env(:pont, :master_token, previous), else: Application.delete_env(:pont, :master_token)
    end)

    assert request("GET", "/health") == {200, "ok"}
    assert request("GET", "/status") == {401, "unauthorized"}
    assert request("GET", "/acp") == {401, "unauthorized"}
    assert request("GET", "/agent") == {401, "unauthorized"}

    {200, body} = request("GET", "/status", [{"authorization", "Bearer sekret"}])
    assert Jason.decode!(body)["runtimes"] == []

    assert {:ok, conn, _ref, _ws} = upgrade("/acp?token=sekret")
    Mint.HTTP.close(conn)
    assert {:ok, conn, _ref, _ws} = upgrade("/agent", [{"authorization", "Bearer sekret"}])
    Mint.HTTP.close(conn)
  end

  defp request(method, path, headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 18_091, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, nil)
    assert {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)
    status = Enum.find_value(responses, fn {:status, ^ref, code} -> code; _ -> nil end)
    body = Enum.find_value(responses, "", fn {:data, ^ref, chunk} -> chunk; _ -> nil end)
    Mint.HTTP.close(conn)
    {status, body}
  end

  defp upgrade(path, headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 18_091, protocols: [:http1], mode: :passive)

    with {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
         {:ok, conn, status, headers} <- await(conn, ref, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, ref, websocket}
    else
      other -> other
    end
  end

  defp await(conn, ref, acc) do
    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      status = Enum.find_value(acc, fn {:status, ^ref, status} -> status; _ -> nil end)
      headers = Enum.find_value(acc, fn {:headers, ^ref, headers} -> headers; _ -> nil end) || []
      {:ok, conn, status, headers}
    else
      {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)
      await(conn, ref, acc ++ responses)
    end
  end
end
