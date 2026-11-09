defmodule AgentLink.OpenCodeLiveTest do
  use ExUnit.Case, async: false

  @port 18_099
  @model "xai/grok-4.20-0309-non-reasoning"

  @tag :wrapped
  @tag timeout: 240_000
  test "the release asks the agent for a landing page" do
    dir = tmp_dir()
    {port, page_dir} = start_binary(System.fetch_env!("AGENTLINK_BIN"), dir)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn -> File.rm_rf(dir) end)

    owned =
      case AgentLink.OwnedStop.capture(os_pid) do
        {:ok, owned} ->
          owned

        :error ->
          flunk("could not read /proc starttime for launcher pid #{os_pid}")
      end

    on_exit(fn -> AgentLink.OwnedStop.stop(owned) end)

    try do
      assert :ok = wait_runtime()
      request_page(page_dir)
    after
      AgentLink.OwnedStop.stop(owned)

      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end
  end

  defp request_page(page_dir) do
    {:ok, client} = AgentLink.LiveClient.start(@port)

    assert {:ok, %{"result" => %{"runtimes" => [%{"name" => "opencode"}]}}} =
             AgentLink.LiveClient.request(client, "runtime/list", %{})

    assert {:ok, %{"result" => %{"name" => "opencode"}}} =
             AgentLink.LiveClient.request(client, "runtime/select", %{"name" => "opencode"})

    assert {:ok, %{"result" => %{}}} =
             AgentLink.LiveClient.request(client, "initialize", %{
               "protocolVersion" => 1,
               "clientCapabilities" => %{
                 "fs" => %{"readTextFile" => false, "writeTextFile" => false},
                 "terminal" => false
               },
               "clientInfo" => %{
                 "name" => "agentlink-live-test",
                 "title" => "AgentLink live test",
                 "version" => "0.1.0"
               }
             })

    assert {:ok, %{"result" => %{"sessionId" => session_id}}} =
             AgentLink.LiveClient.request(client, "session/new", %{
               "cwd" => page_dir,
               "mcpServers" => []
             })

    assert {:ok, %{"result" => %{"configOptions" => options}}} =
             AgentLink.LiveClient.request(client, "session/set_config_option", %{
               "sessionId" => session_id,
               "configId" => "model",
               "value" => @model
             })

    assert %{"id" => "model", "currentValue" => @model} =
             Enum.find(options, &(&1["id"] == "model"))

    assert {:ok, %{"result" => %{"stopReason" => "end_turn"}}} =
             AgentLink.LiveClient.request(
               client,
               "session/prompt",
               %{
                 "sessionId" => session_id,
                 "prompt" => [
                   %{
                     "type" => "text",
                     "text" =>
                       "Write index.html in the current directory. One short landing page for this control plane: a WebSocket plane, an agent relay beside the agent, and a registry of runtimes. No other files."
                   }
                 ]
               },
               150_000
             )

    html = find_html(page_dir)
    assert {:ok, document} = File.read!(html) |> Floki.parse_document()
    assert Floki.find(document, "html") != []
    assert Floki.find(document, "head title") != []
    assert Floki.find(document, "body") != []

    text = Floki.text(document)
    assert text =~ ~r/control plane/i
    assert text =~ ~r/websocket/i
    assert text =~ ~r/relay/i
    assert text =~ ~r/registry/i
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "agentlink-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp paths_under(home) do
    root = System.user_home!()

    {under_home(AgentLink.Paths.link(), root, home),
     under_home(AgentLink.Paths.default_workdir(), root, home)}
  end

  defp start_binary(bin, dir) do
    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    {link, page_dir} = paths_under(home)
    File.mkdir_p!(Path.dirname(link))
    File.mkdir_p!(page_dir)
    File.write!(Path.join(page_dir, "opencode.json"), model_config())
    opencode = System.get_env("OPENCODE_BIN") || System.find_executable("opencode")
    unless is_binary(opencode) and File.exists?(opencode), do: flunk("opencode not found")
    File.write!(link, link_json(opencode))

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["--port", Integer.to_string(@port), "--token", "live-token"]},
        {:env, binary_env(home)}
      ])

    {port, page_dir}
  end

  defp under_home(path, root, home) do
    relative = Path.relative_to(path, root)
    if relative == path, do: flunk("AgentLink.Paths returned #{path}, which is not under #{root}")
    Path.join(home, relative)
  end

  defp model_config do
    Jason.encode!(%{"$schema" => "https://opencode.ai/config.json", "model" => @model})
  end

  defp link_json(opencode) do
    Jason.encode!(%{
      "name" => "opencode",
      "label" => "this machine",
      "program" => "opencode",
      "plane_url" => "ws://127.0.0.1:#{@port}/agent",
      "command" => opencode,
      "args" => ["acp"]
    })
  end

  defp binary_env(home) do
    real_home = System.user_home!()

    System.get_env()
    |> Map.put("HOME", home)
    |> Map.put("XDG_DATA_HOME", Path.join(real_home, ".local/share"))
    |> Map.put("XDG_CONFIG_HOME", Path.join(real_home, ".config"))
    |> Map.put("XDG_STATE_HOME", Path.join(real_home, ".local/state"))
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp find_html(dir) do
    case Path.wildcard(Path.join(dir, "**/*.html")) do
      [path | _] -> path
      [] -> flunk("OpenCode wrote no html in #{dir}: #{inspect(File.ls!(dir))}")
    end
  end

  defp wait_runtime(left \\ 60) do
    flush_binary()

    case status_runtimes() do
      [%{"name" => "opencode"}] ->
        :ok

      _ when left > 0 ->
        Process.sleep(500)
        wait_runtime(left - 1)

      other ->
        {:error, other}
    end
  end

  defp flush_binary do
    receive do
      {_port, {:data, data}} ->
        IO.binwrite(data)
        flush_binary()

      {_port, {:exit_status, status}} ->
        IO.puts("agentlink binary exited #{status}")
    after
      0 -> :ok
    end
  end

  defp status_runtimes do
    case Mint.HTTP.connect(:http, "127.0.0.1", @port, mode: :passive) do
      {:ok, conn} ->
        {:ok, conn, ref} =
          Mint.HTTP.request(conn, "GET", "/status", [{"authorization", "Bearer live-token"}], nil)

        {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 2_000)
        Mint.HTTP.close(conn)

        body =
          responses
          |> Enum.flat_map(fn
            {:data, ^ref, chunk} -> [chunk]
            _ -> []
          end)
          |> IO.iodata_to_binary()

        Jason.decode!(body)["runtimes"]

      _ ->
        []
    end
  end
end

defmodule AgentLink.LiveClient do
  @moduledoc false
  use GenServer

  def start(port), do: GenServer.start_link(__MODULE__, port)

  def request(pid, method, params, timeout \\ 20_000) do
    GenServer.call(pid, {:request, method, params}, timeout)
  end

  @impl true
  def init(port) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, "/acp", [{"authorization", "Bearer live-token"}])

    {:ok, conn, 101, headers} = await(conn, ref, [])
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers)
    {:ok, conn} = Mint.HTTP.set_mode(conn, :active)
    {:ok, %{conn: conn, ref: ref, websocket: websocket, next: 1, waiters: %{}}}
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = state.next

    state =
      send_json(state, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

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
          {nil, _} ->
            state

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
      status =
        Enum.find_value(acc, fn
          {:status, ^ref, status} -> status
          _ -> nil
        end)

      headers =
        Enum.find_value(acc, [], fn
          {:headers, ^ref, headers} -> headers
          _ -> nil
        end)

      {:ok, conn, status, headers}
    else
      {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 5_000)
      await(conn, ref, acc ++ responses)
    end
  end
end
