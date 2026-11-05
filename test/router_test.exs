defmodule AgentLink.RouterTest do
  use ExUnit.Case, async: false

  defmodule DenyClaim do
    @behaviour AgentLink.Access

    def authenticate(_conn), do: {:ok, %AgentLink.Access.Subject{id: "admin", role: :admin}}
    def allowed?(_subject, _name), do: true
    def claim(_subject, _name), do: :reject
    def prepare(_mode), do: {:ok, ""}
  end

  setup do
    previous = Application.get_env(:agent_link, :master_token)
    start_supervised!(AgentLink.Registry)
    start_supervised!(AgentLink.Plane.Sessions)
    start_supervised!(AgentLink.Plane)

    start_supervised!(
      {Bandit, plug: AgentLink.Router, scheme: :http, port: 18_091, ip: {127, 0, 0, 1}}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :master_token, previous),
        else: Application.delete_env(:agent_link, :master_token)
    end)

    :ok
  end

  test "health, status, and an unknown path" do
    Application.put_env(:agent_link, :master_token, "sekret")

    assert request("GET", "/health") == {200, "ok"}
    {200, body} = request("GET", "/status", [{"authorization", "Bearer sekret"}])
    decoded = Jason.decode!(body)
    assert decoded["plane"] == "127.0.0.1:#{Application.fetch_env!(:agent_link, :port)}"
    assert decoded["runtimes"] == []
    assert {404, "not found"} = request("GET", "/nope")
  end

  test "the app and agent paths upgrade to a websocket" do
    Application.put_env(:agent_link, :master_token, "sekret")
    assert {:ok, conn, _ref, _ws} = upgrade("/acp?token=sekret")
    Mint.HTTP.close(conn)

    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :master_token, previous),
        else: Application.delete_env(:agent_link, :master_token)
    end)

    assert {:ok, conn, ref, websocket} = upgrade("/agent", [{"authorization", "Bearer sekret"}])

    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => %{"name" => "lab", "label" => "Bench"}
      })

    {:ok, _websocket, data} = Mint.WebSocket.encode(websocket, {:text, hello})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, _conn} = Mint.HTTP.set_mode(conn, :active)
    Process.sleep(100)
    assert AgentLink.Registry.pid("lab")
    Mint.HTTP.close(conn)
  end

  test "a second hello for a live name is rejected and the holder stays up" do
    Application.put_env(:agent_link, :master_token, "sekret")
    headers = [{"authorization", "Bearer sekret"}]

    assert {:ok, conn1, ref1, websocket1} = upgrade("/agent", headers)
    {conn1, websocket1} = say_hello(conn1, ref1, websocket1, "opencode")
    {:ok, conn1} = Mint.HTTP.set_mode(conn1, :active)
    first = AgentLink.TestHelpers.await_pid("opencode")

    assert {:ok, conn2, ref2, websocket2} = upgrade("/agent", headers)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {conn2, websocket2} = say_hello(conn2, ref2, websocket2, "opencode")
        send(self(), {:rejected, recv_until_close(conn2, websocket2), conn2})
      end)

    assert_receive {:rejected, frames, conn2}
    assert {:close, 4001, AgentLink.AgentSocketProtocol.reason(:name_taken, "opencode")} in frames

    assert log =~
             "uplink rejected name=opencode another uplink is already connected with this name"

    holder_frames = collect_frames(conn1, websocket1, 200)
    refute Enum.any?(holder_frames, &match?({:close, _, _}, &1))
    assert AgentLink.Registry.pid("opencode") == first
    assert Process.alive?(first)

    frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{}})
    {:ok, _websocket1, data} = Mint.WebSocket.encode(websocket1, {:text, frame})
    assert {:ok, _conn1} = Mint.WebSocket.stream_request_body(conn1, ref1, data)
    Process.sleep(30)
    assert AgentLink.Registry.pid("opencode") == first
    assert Process.alive?(first)
    Mint.HTTP.close(conn1)
    Mint.HTTP.close(conn2)
  end

  test "a token guards status and both sockets, and health stays open" do
    previous = Application.get_env(:agent_link, :master_token)
    Application.put_env(:agent_link, :master_token, "sekret")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :master_token, previous),
        else: Application.delete_env(:agent_link, :master_token)
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

  test "bad-name, not-allowed, and oversized-instance rejections reach the wire" do
    Application.put_env(:agent_link, :master_token, "sekret")
    previous = Application.get_env(:agent_link, :access)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_link, :access, previous),
        else: Application.delete_env(:agent_link, :access)
    end)

    for {name, attrs, policy, code, reason} <- [
          {nil, %{}, AgentLink.Access.Single, 4003, "link name must be a short slug"},
          {"lab",
           %{
             "instance" =>
               String.duplicate("a", AgentLink.AgentSocketProtocol.max_instance_bytes() + 1)
           }, AgentLink.Access.Single, 4002, "instance id is too long; max is 128 bytes"},
          {"lab", %{}, DenyClaim, 4004, "uplink is not allowed"}
        ] do
      Application.put_env(:agent_link, :access, policy)
      assert {:ok, conn, ref, websocket} = upgrade("/agent", [{"authorization", "Bearer sekret"}])
      {conn, websocket} = say_hello(conn, ref, websocket, name, attrs)
      assert {:close, code, reason} in recv_until_close(conn, websocket)
      assert AgentLink.Registry.list() == []
      Mint.HTTP.close(conn)
    end
  end

  defp request(method, path, headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 18_091, mode: :passive)
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, nil)
    assert {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)

    status =
      Enum.find_value(responses, fn
        {:status, ^ref, code} -> code
        _ -> nil
      end)

    body =
      Enum.find_value(responses, "", fn
        {:data, ^ref, chunk} -> chunk
        _ -> nil
      end)

    Mint.HTTP.close(conn)
    {status, body}
  end

  defp upgrade(path, headers \\ []) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, "127.0.0.1", 18_091, protocols: [:http1], mode: :passive)

    with {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
         {:ok, conn, status, headers} <- await(conn, ref, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, ref, websocket}
    else
      other -> other
    end
  end

  defp say_hello(conn, ref, websocket, name, attrs \\ %{}) do
    hello =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "agentlink.uplink",
        "params" => Map.merge(%{"name" => name, "label" => "Bench"}, attrs)
      })

    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, hello})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  defp recv_until_close(conn, websocket, frames \\ []) do
    case Mint.WebSocket.recv(conn, 0, 1_000) do
      {:ok, conn, responses} ->
        {websocket, extra} = decode_frames(websocket, responses)
        frames = frames ++ extra

        if Enum.any?(frames, &match?({:close, _, _}, &1)) do
          frames
        else
          recv_until_close(conn, websocket, frames)
        end

      {:error, _conn, _reason, responses} ->
        {_websocket, extra} = decode_frames(websocket, responses)
        frames ++ extra
    end
  end

  defp collect_frames(conn, websocket, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    {_, _, frames} = collect_frames(conn, websocket, [], deadline)
    frames
  end

  defp collect_frames(conn, websocket, frames, deadline) do
    wait = deadline - System.monotonic_time(:millisecond)

    if wait <= 0 do
      {conn, websocket, frames}
    else
      receive do
        message ->
          case Mint.WebSocket.stream(conn, message) do
            {:ok, conn, responses} ->
              {websocket, extra} = decode_frames(websocket, responses)
              frames = frames ++ extra

              if Enum.any?(frames, &match?({:close, _, _}, &1)) do
                {conn, websocket, frames}
              else
                collect_frames(conn, websocket, frames, deadline)
              end

            {:error, conn, _reason, responses} ->
              {_websocket, extra} = decode_frames(websocket, responses)
              {conn, websocket, frames ++ extra}

            :unknown ->
              collect_frames(conn, websocket, frames, deadline)
          end
      after
        wait ->
          {conn, websocket, frames}
      end
    end
  end

  defp decode_frames(websocket, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, _ref, data}, {websocket, frames} ->
        {:ok, websocket, extra} = Mint.WebSocket.decode(websocket, data)
        {websocket, frames ++ extra}

      _, acc ->
        acc
    end)
  end

  defp await(conn, ref, acc) do
    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      status =
        Enum.find_value(acc, fn
          {:status, ^ref, status} -> status
          _ -> nil
        end)

      headers =
        Enum.find_value(acc, fn
          {:headers, ^ref, headers} -> headers
          _ -> nil
        end) || []

      {:ok, conn, status, headers}
    else
      {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 1_000)
      await(conn, ref, acc ++ responses)
    end
  end
end
