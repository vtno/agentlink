defmodule Pont.OpenCodeLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @port 18_099

  @tag timeout: 180_000
  test "a client asks the running agent for a landing page" do
    dir = Path.join(System.tmp_dir!(), "acp-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "opencode.json"), ~s({"$schema":"https://opencode.ai/config.json","model":"xai/grok-4.20-0309-non-reasoning"}))

    previous = %{
      plane: System.get_env("ACP_PLANE_URL"),
      name: System.get_env("ACP_RUNTIME_NAME"),
      harness: Application.get_env(:pont, :harness),
      mode: Application.get_env(:pont, :mode),
      port: Application.get_env(:pont, :port),
      workdir: Application.get_env(:pont, :workdir)
    }

    System.put_env("ACP_PLANE_URL", "ws://127.0.0.1:#{@port}/agent")
    System.put_env("ACP_RUNTIME_NAME", "opencode")
    Application.put_env(:pont, :harness, Pont.OpenCode)
    Application.put_env(:pont, :mode, :all)
    Application.put_env(:pont, :port, @port)
    Application.put_env(:pont, :workdir, dir)

    on_exit(fn ->
      stop_app()
      restore_env(previous)
      File.rm_rf(dir)
    end)

    assert {:ok, _} = Pont.Application.start(:normal, [])
    assert :ok = wait_runtime()

    {:ok, client} = Pont.LiveClient.start(@port)

    assert {:ok, %{"result" => %{"runtimes" => [%{"name" => "opencode"}]}}} =
             Pont.LiveClient.request(client, "runtime/list", %{})

    assert {:ok, %{"result" => %{"name" => "opencode"}}} =
             Pont.LiveClient.request(client, "runtime/select", %{"name" => "opencode"})

    assert {:ok, %{"result" => %{}}} =
             Pont.LiveClient.request(client, "initialize", %{
               "protocolVersion" => 1,
               "clientCapabilities" => %{
                 "fs" => %{"readTextFile" => false, "writeTextFile" => false},
                 "terminal" => false
               },
               "clientInfo" => %{"name" => "acp-live-test", "title" => "ACP live test", "version" => "0.1.0"}
             })

    assert {:ok, %{"result" => %{"sessionId" => session_id}}} =
             Pont.LiveClient.request(client, "session/new", %{"cwd" => dir, "mcpServers" => []})

    _ = Pont.LiveClient.request(client, "session/set_config_option", %{
      "sessionId" => session_id,
      "configId" => "model",
      "value" => "xai/grok-4.20-0309-non-reasoning"
    })

    assert {:ok, %{"result" => %{"stopReason" => "end_turn"}}} =
             Pont.LiveClient.request(
               client,
               "session/prompt",
               %{
                 "sessionId" => session_id,
                 "prompt" => [
                   %{
                     "type" => "text",
                     "text" =>
                       "Write index.html in the current directory. One short landing page for this control plane: a WebSocket plane, a sidecar beside the agent, and a registry of runtimes. No other files."
                   }
                 ]
               },
               150_000
             )

    html = find_html(dir)
    body = File.read!(html)
    assert body =~ ~r/<html/i
    assert body =~ ~r/control plane/i
  end

  defp find_html(dir) do
    case Path.wildcard(Path.join(dir, "**/*.html")) do
      [path | _] -> path
      [] -> flunk("OpenCode wrote no html in #{dir}: #{inspect(File.ls!(dir))}")
    end
  end

  defp wait_runtime(left \\ 60) do
    case status_runtimes() do
      [%{"name" => "opencode"}] -> :ok
      _ when left > 0 ->
        Process.sleep(500)
        wait_runtime(left - 1)

      other ->
        {:error, other}
    end
  end

  defp status_runtimes do
    case Mint.HTTP.connect(:http, "127.0.0.1", @port, mode: :passive) do
      {:ok, conn} ->
        {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/status", [], nil)
        {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 2_000)
        Mint.HTTP.close(conn)

        body =
          responses
          |> Enum.flat_map(fn {:data, ^ref, chunk} -> [chunk]; _ -> [] end)
          |> IO.iodata_to_binary()

        Jason.decode!(body)["runtimes"]

      _ ->
        []
    end
  end

  defp stop_app do
    case Process.whereis(Pont.Supervisor) do
      nil ->
        :ok

      pid ->
        Process.unlink(pid)
        Supervisor.stop(pid, :shutdown, 10_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(previous) do
    put_or_delete("ACP_PLANE_URL", previous.plane)
    put_or_delete("ACP_RUNTIME_NAME", previous.name)
    Application.put_env(:pont, :harness, previous.harness)
    Application.put_env(:pont, :mode, previous.mode)
    Application.put_env(:pont, :port, previous.port)
    Application.put_env(:pont, :workdir, previous.workdir)
  end

  defp put_or_delete(key, nil), do: System.delete_env(key)
  defp put_or_delete(key, value), do: System.put_env(key, value)
end

defmodule Pont.LiveClient do
  @moduledoc false
  use GenServer

  def start(port), do: GenServer.start_link(__MODULE__, port)

  def request(pid, method, params, timeout \\ 20_000) do
    GenServer.call(pid, {:request, method, params}, timeout)
  end

  @impl true
  def init(port) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/acp", [])
    {:ok, conn, 101, headers} = await(conn, ref, [])
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :active)
    {:ok, %{conn: conn, ref: ref, websocket: websocket, next: 1, waiters: %{}}}
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = state.next
    state = send_json(state, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    {:noreply, %{state | next: id + 1, waiters: Map.put(state.waiters, id, from)}}
  end

  @impl true
  def handle_info(message, %{conn: conn} = state) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &apply_response/2)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp apply_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &apply_frame/2)

      {:error, websocket, _} ->
        %{state | websocket: websocket}
    end
  end

  defp apply_response(_, state), do: state

  defp apply_frame({:text, payload}, state), do: on_payload(payload, state)
  defp apply_frame({:binary, payload}, state), do: on_payload(payload, state)
  defp apply_frame({:ping, payload}, state), do: send_frame(state, {:pong, payload})
  defp apply_frame(_, state), do: state

  defp on_payload(payload, state) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id} = message} when not is_nil(id) and is_map_key(message, "method") ->
        reply = answer(message)
        if reply, do: send_json(state, reply), else: state

      {:ok, %{"id" => id} = message} when not is_nil(id) ->
        case Map.pop(state.waiters, id) do
          {nil, _} -> state
          {from, waiters} ->
            GenServer.reply(from, {:ok, message})
            %{state | waiters: waiters}
        end

      _ ->
        state
    end
  end

  defp answer(%{"method" => "session/request_permission", "id" => id, "params" => params}) do
    options = params["options"] || []

    chosen =
      Enum.find(options, fn option ->
        option["kind"] in ["allow_once", "allow_always"]
      end) || List.first(options)

    result =
      if chosen && chosen["optionId"] do
        %{"outcome" => %{"outcome" => "selected", "optionId" => chosen["optionId"]}}
      else
        %{"outcome" => %{"outcome" => "cancelled"}}
      end

    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp answer(%{"method" => "elicitation/create", "id" => id}) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"action" => "cancel"}}
  end

  defp answer(_), do: nil

  defp send_json(state, message), do: send_frame(state, {:text, Jason.encode!(message)})

  defp send_frame(state, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
    %{state | conn: conn, websocket: websocket}
  end

  defp await(conn, ref, acc) do
    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      status = Enum.find_value(acc, fn {:status, ^ref, status} -> status; _ -> nil end)
      headers = Enum.find_value(acc, [], fn {:headers, ^ref, headers} -> headers; _ -> nil end)
      {:ok, conn, status, headers}
    else
      {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 5_000)
      await(conn, ref, acc ++ responses)
    end
  end
end
