defmodule AgentLink.ApplicationTest.ClosedStdio do
  def open(_owner), do: {:error, :closed}
  def write(_term, _data), do: :closed
  def close(_term), do: :ok
end

defmodule AgentLink.ApplicationTest.EofAtOpen do
  def open(owner) when is_pid(owner) do
    send(owner, {owner, :eof})
    {:ok, owner}
  end

  def write(_term, _data), do: :ok
  def close(_term), do: :ok
end

defmodule AgentLink.ApplicationTest.ObservedTransport do
  @moduledoc """
  `AgentLink.Transport` for connect boot tests. Calls go to
  `AgentLink.FakeTransport`.

  `start_link/1` sends `{:connect_dial, pid, view}` to the
  `:connect_observer` pid. `view` is the `:url`, `:headers`, and
  `:default_path` the client relay passed. `send_message/2` sends
  `{:connect_plane, message}` after `message` is in `FakeTransport.sent/1`.
  """

  @behaviour AgentLink.Transport

  @impl true
  def start_link(opts) do
    case AgentLink.FakeTransport.start_link(opts) do
      {:ok, pid} = ok ->
        send(observer(), {:connect_dial, pid, dial(opts)})
        ok

      other ->
        other
    end
  end

  @impl true
  def send_message(pid, message) when is_map(message) do
    :ok = AgentLink.FakeTransport.send_message(pid, message)
    # `sent/1` runs after the cast. A message still queued is not on the wire.
    if message in AgentLink.FakeTransport.sent(pid),
      do: send(observer(), {:connect_plane, message})

    :ok
  end

  @impl true
  def hold(pid), do: AgentLink.FakeTransport.hold(pid)

  @impl true
  def reconnect(pid, url) when is_binary(url), do: AgentLink.FakeTransport.reconnect(pid, url)

  @impl true
  def preface(pid, message) when is_map(message) or is_nil(message) do
    AgentLink.FakeTransport.preface(pid, message)
  end

  @impl true
  def url(pid, url) when is_binary(url), do: AgentLink.FakeTransport.url(pid, url)

  defp dial(opts) do
    %{
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.fetch!(opts, :headers),
      default_path: Keyword.fetch!(opts, :default_path)
    }
  end

  defp observer, do: Application.fetch_env!(:agent_link, :connect_observer)
end

defmodule AgentLink.ApplicationTest.ObservedStdio do
  @moduledoc """
  `AgentLink.Stdio` for connect boot tests. Calls go to `AgentLink.FakeStdio`.

  `open/1` sends `{:connect_stdio, pid}` to the `:connect_observer` pid.
  """

  @behaviour AgentLink.Stdio

  @impl true
  def open(owner) when is_pid(owner) do
    case AgentLink.FakeStdio.open(owner) do
      {:ok, pid} = ok ->
        send(observer(), {:connect_stdio, pid})
        ok

      other ->
        other
    end
  end

  @impl true
  def write(term, data), do: AgentLink.FakeStdio.write(term, data)

  @impl true
  def close(term), do: AgentLink.FakeStdio.close(term)

  defp observer, do: Application.fetch_env!(:agent_link, :connect_observer)
end

defmodule AgentLink.ApplicationTest.OnceAgent do
  @moduledoc false

  def open(_owner, launch, cwd) do
    if listener = Application.get_env(:agent_link, :agent_listener) do
      send(listener, {:once_open, launch, cwd})
    end

    {:error, "once agent refused\n"}
  end

  def write(_agent, _data), do: :closed
  def close(_agent), do: :ok
end

defmodule AgentLink.ApplicationTest.CrashAgent do
  @moduledoc false
  def open(_owner, _launch, _cwd), do: raise("boom")
  def write(_agent, _data), do: :closed
  def close(_agent), do: :ok
end

defmodule AgentLink.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    Process.flag(:trap_exit, true)
    Application.put_env(:agent_link, :agent_listener, self())

    previous =
      {Application.get_env(:agent_link, :mode), Application.get_env(:agent_link, :port),
       Application.get_env(:agent_link, :link_path)}

    connect_keys = [
      :connect_plane,
      :connect_target,
      :connect_token,
      :config_root,
      :config_env,
      :connect_transport,
      :connect_stdio,
      :connect_observer,
      :halt_listener,
      :connect_watcher
    ]

    connect_env = Map.new(connect_keys, &{&1, Application.get_env(:agent_link, &1)})

    on_exit(fn ->
      Application.delete_env(:agent_link, :agent_listener)
      {mode, port, link_path} = previous
      if mode, do: Application.put_env(:agent_link, :mode, mode)
      if port, do: Application.put_env(:agent_link, :port, port)
      restore_link(link_path)
      Enum.each(connect_env, fn {key, value} -> AgentLink.TestHelpers.restore(key, value) end)

      if pid = Process.whereis(AgentLink.Supervisor) do
        Process.exit(pid, :kill)
        Process.sleep(50)
      end
    end)

    :ok
  end

  test "plane mode does not start an agent relay" do
    Application.put_env(:agent_link, :mode, :plane)
    Application.put_env(:agent_link, :port, 18_096)

    Application.put_env(
      :agent_link,
      :link_path,
      "/tmp/agentlink-plane-missing-#{System.unique_integer([:positive])}.json"
    )

    assert {:ok, _pid} = AgentLink.Application.start(:normal, [])
    assert Process.whereis(AgentLink.Plane)
    assert Process.whereis(AgentLink.Plane.Sessions)
    assert Process.whereis(AgentLink.Registry)
    assert Process.whereis(AgentLink.Plane.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
    refute_client_relay()
  end

  test "relay mode stops when the link file is missing" do
    Application.put_env(:agent_link, :mode, :relay)

    Application.put_env(
      :agent_link,
      :link_path,
      "/tmp/agentlink-missing-#{System.unique_integer([:positive])}.json"
    )

    assert {:error, message} = AgentLink.Application.start(:normal, [])
    assert message =~ "No link file"
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "all mode prints a missing launch once and does not stay up" do
    Application.put_env(:agent_link, :mode, :all)
    Application.put_env(:agent_link, :port, 18_100)

    Application.put_env(
      :agent_link,
      :link_path,
      "/tmp/agentlink-all-missing-#{System.unique_integer([:positive])}.json"
    )

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:error, message} = AgentLink.Application.start(:normal, [])
        assert message =~ "No link file"
        send(self(), {:boot_message, message})
      end)

    assert_received {:boot_message, message}
    assert message =~ "No link file"
    assert stderr =~ "No link file"
    assert length(String.split(stderr, "No link file")) == 2
    refute Process.whereis(AgentLink.Supervisor)
    refute Process.whereis(AgentLink.Plane)
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "an open error before startup is one attempt and one message" do
    previous = Application.get_env(:agent_link, :agent_module)
    Application.put_env(:agent_link, :agent_module, AgentLink.ApplicationTest.OnceAgent)
    on_exit(fn -> AgentLink.TestHelpers.restore(:agent_module, previous) end)
    Application.put_env(:agent_link, :mode, :relay)
    write_link()

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:error, message} = AgentLink.Application.start(:normal, [])
        assert message =~ "once agent refused"
        send(self(), {:boot_message, message})
      end)

    assert_received {:boot_message, _message}
    assert stderr =~ "once agent refused"
    assert length(String.split(stderr, "once agent refused")) == 2
    assert_received {:once_open, %AgentLink.Agent.Launch{}, _cwd}
    refute_received {:once_open, _launch, _cwd}
    refute Process.whereis(AgentLink.Supervisor)
  end

  test "a raised open stays a supervisor error" do
    previous = Application.get_env(:agent_link, :agent_module)
    Application.put_env(:agent_link, :agent_module, AgentLink.ApplicationTest.CrashAgent)
    on_exit(fn -> AgentLink.TestHelpers.restore(:agent_module, previous) end)
    Application.put_env(:agent_link, :mode, :relay)
    write_link()

    assert {:error, reason} = AgentLink.Application.start(:normal, [])
    refute is_binary(reason)
    refute Process.whereis(AgentLink.Supervisor)
  end

  test "relay mode starts only the relay" do
    if pid = Process.whereis(AgentLink.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end

    write_link()
    Application.put_env(:agent_link, :mode, :relay)
    assert {:ok, _pid} = AgentLink.Application.start(:normal, [])
    assert_receive {:agent_opened, _agent, _launch, _cwd}
    assert Process.whereis(AgentLink.Relay.Agent)
    refute Process.whereis(AgentLink.Plane)
    refute Process.whereis(AgentLink.Plane.Sessions)
    refute Process.whereis(AgentLink.Plane.Supervisor)
    refute_client_relay()
  end

  test "all mode starts both" do
    start_all(18_097)
    assert Process.whereis(AgentLink.Plane)
    assert Process.whereis(AgentLink.Relay.Agent)
    assert Process.whereis(AgentLink.Relay.Agent.Supervisor)
    assert plane_only?(AgentLink.Plane.Supervisor)
    refute_client_relay()
  end

  test "connect mode starts only the client relay from the config files" do
    root = connect_root()
    write_connect_config!(root, %{"plane" => "ws://from-file/acp", "target" => "from-file"})
    write_connect_token!(root, "from-file\n")
    put_connect(root, %{}, nil, nil, nil)

    assert {:ok, sup} = AgentLink.Application.start(:normal, [])

    assert [{AgentLink.Relay.Client, _client, :worker, [AgentLink.Relay.Client]}] =
             Supervisor.which_children(sup)

    refute Process.whereis(AgentLink.Plane)
    refute Process.whereis(AgentLink.Plane.Sessions)
    refute Process.whereis(AgentLink.Plane.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
    refute Process.whereis(AgentLink.Relay.Agent.Supervisor)
    refute Process.whereis(AgentLink.Registry)

    {transport, dial} = connect_dial!()
    assert dial.url == "ws://from-file/acp"
    assert dial.default_path == "/acp"
    assert dial.headers == [{"authorization", "Bearer from-file"}]

    deliver_runtimes(transport, ["from-file"])
    assert_runtime_select("from-file")
  end

  test "connect mode prefers a flag over the environment and the environment over the file" do
    root = connect_root()
    write_connect_config!(root, %{"plane" => "ws://from-file/acp", "target" => "from-file"})
    write_connect_token!(root, "from-file")

    put_connect(
      root,
      %{
        "AGENTLINK_PLANE" => "ws://from-env/acp",
        "AGENTLINK_TARGET" => "from-env",
        "AGENTLINK_TOKEN" => "from-env"
      },
      "ws://from-flag/acp",
      nil,
      nil
    )

    assert {:ok, _sup} = AgentLink.Application.start(:normal, [])
    {transport, dial} = connect_dial!()
    assert dial.url == "ws://from-flag/acp"
    assert dial.headers == [{"authorization", "Bearer from-env"}]

    deliver_runtimes(transport, ["from-file", "from-env"])
    assert_runtime_select("from-env")
  end

  test "connect mode exits when the plane URL or the token is missing" do
    root = connect_root()

    put_connect(root, %{}, nil, nil, "sekret")
    assert {:error, message} = AgentLink.Application.start(:normal, [])
    assert message =~ "needs a plane URL"
    assert message =~ Path.join(root, "config")
    refute Process.whereis(AgentLink.Supervisor)

    put_connect(root, %{}, "ws://plane/acp", nil, nil)
    assert {:error, message} = AgentLink.Application.start(:normal, [])
    assert message =~ "needs a token"
    assert message =~ Path.join(root, "token")
    refute Process.whereis(AgentLink.Relay.Client)
  end

  test "connect mode exits when the token file cannot be read" do
    root = connect_root()
    write_connect_config!(root, %{"plane" => "ws://plane/acp"})
    write_connect_token!(root, "sekret", 0o644)
    put_connect(root, %{}, nil, nil, nil)

    assert {:error, message} = AgentLink.Application.start(:normal, [])
    assert message =~ "0644"
    assert message =~ Path.join(root, "token")
    refute Process.whereis(AgentLink.Supervisor)
  end

  test "connect mode exits when stdio fails to open" do
    root = connect_root()
    put_connect(root, %{}, "ws://plane/acp", "lab", "sekret")
    Application.put_env(:agent_link, :connect_stdio, AgentLink.ApplicationTest.ClosedStdio)

    assert {:error, "stdio open failed: :closed"} = AgentLink.Application.start(:normal, [])
    refute Process.whereis(AgentLink.Supervisor)
  end

  test "a bad target exits 1 and the client relay stays down" do
    root = connect_root()
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect(root, %{}, "ws://plane/acp", "missing", "sekret")

    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    assert_receive {:connect_watching, _watcher}
    {transport, _dial} = connect_dial!()
    client = connect_client!(sup)
    ref = Process.monitor(client)

    deliver_runtimes(transport, ["lab"])

    assert_receive {:DOWN, ^ref, :process, ^client,
                    {:shutdown,
                     "\"missing\" is not online. Online agents: \"lab\". Pass --target.\n"}}

    assert_receive {:connect_exit, 1}

    assert [{AgentLink.Relay.Client, :undefined, :worker, [AgentLink.Relay.Client]}] =
             Supervisor.which_children(sup)
  end

  test "stdin already closed when the client relay starts exits 0" do
    root = connect_root()
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect(root, %{}, "ws://plane/acp", "lab", "sekret")
    Application.put_env(:agent_link, :connect_stdio, AgentLink.ApplicationTest.EofAtOpen)

    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    assert_receive {:connect_exit, 0}
    refute_received {:connect_exit, 1}

    assert [{AgentLink.Relay.Client, :undefined, :worker, [AgentLink.Relay.Client]}] =
             Supervisor.which_children(sup)
  end

  test "stdin closing exits 0" do
    root = connect_root()
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect(root, %{}, "ws://plane/acp", "lab", "sekret")

    assert {:ok, _sup} = AgentLink.Application.start(:normal, [])
    assert_receive {:connect_watching, _watcher}
    stdio = connect_stdio!()
    :ok = AgentLink.FakeStdio.eof(stdio)

    assert_receive {:connect_exit, 0}
    refute_received {:connect_exit, 1}
  end

  test "a client relay crash starts another, and a later bad target exits 1" do
    root = connect_root()
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect(root, %{}, "ws://plane/acp", "missing", "sekret")

    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    assert_receive {:connect_watching, _watcher}
    {_transport, _dial} = connect_dial!()
    client = connect_client!(sup)
    ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^ref, :process, ^client, :killed}

    assert_receive {:connect_watching, _watcher}
    refute_received {:connect_exit, _}
    {transport, _dial} = connect_dial!()
    new_client = connect_client!(sup)
    assert is_pid(new_client)
    assert new_client != client

    deliver_runtimes(transport, ["lab"])
    assert_receive {:connect_exit, 1}
  end

  test "AgentLink.Supervisor dying exits 1" do
    root = connect_root()
    Application.put_env(:agent_link, :halt_listener, self())
    put_connect(root, %{}, "ws://plane/acp", "lab", "sekret")

    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    assert_receive {:connect_watching, _watcher}
    assert_receive {:connect_supervisor, ^sup}
    refute_received {:connect_exit, _}

    ref = Process.monitor(sup)
    Process.exit(sup, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sup, :killed}
    assert_receive {:connect_exit, 1}
    refute_received {:connect_exit, 0}
  end

  test "a bad launch after startup stops the relay supervisor and leaves the plane" do
    start_all(18_101)
    File.write!(Application.fetch_env!(:agent_link, :link_path), ~s({"name":"opencode"}))
    supervisor = Process.whereis(AgentLink.Relay.Agent.Supervisor)
    ref = Process.monitor(supervisor)
    Process.exit(Process.whereis(AgentLink.Relay.Agent), :kill)

    assert_receive {:DOWN, ^ref, :process, ^supervisor, _}
    assert Process.alive?(Process.whereis(AgentLink.Plane))
    assert Process.alive?(Process.whereis(AgentLink.Supervisor))
    refute Process.whereis(AgentLink.Relay.Agent.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
  end

  test "a bad launch after startup stops the application supervisor in relay mode" do
    if pid = Process.whereis(AgentLink.Supervisor) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    write_link()
    Application.put_env(:agent_link, :mode, :relay)
    assert {:ok, sup} = AgentLink.Application.start(:normal, [])
    assert_receive {:agent_opened, _agent, _launch, _cwd}
    File.write!(Application.fetch_env!(:agent_link, :link_path), ~s({"name":"opencode"}))
    ref = Process.monitor(sup)
    Process.exit(Process.whereis(AgentLink.Relay.Agent), :kill)

    assert_receive {:DOWN, ^ref, :process, ^sup, _}
    refute Process.whereis(AgentLink.Supervisor)
    refute Process.whereis(AgentLink.Plane)
  end

  test "an agent relay crash loop leaves the plane up" do
    start_all(18_098)
    supervisor = Process.whereis(AgentLink.Relay.Agent.Supervisor)
    supervisor_ref = Process.monitor(supervisor)

    crash_until_down(supervisor, supervisor_ref, 20)
    Process.sleep(50)
    assert Process.alive?(Process.whereis(AgentLink.Plane))
    assert Process.alive?(Process.whereis(AgentLink.Registry))
    assert Process.alive?(Process.whereis(AgentLink.Plane.Supervisor))
    assert Process.alive?(Process.whereis(AgentLink.Supervisor))
    assert plane_only?(AgentLink.Plane.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
    refute Process.whereis(AgentLink.Relay.Agent.Supervisor)
  end

  defp start_all(port) do
    if pid = Process.whereis(AgentLink.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end

    Application.put_env(:agent_link, :mode, :all)
    Application.put_env(:agent_link, :port, port)
    write_link()
    assert {:ok, _pid} = AgentLink.Application.start(:normal, [])
    assert_receive {:agent_opened, _agent, _launch, _cwd}
  end

  defp refute_client_relay do
    ids = AgentLink.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    refute AgentLink.Relay.Client in ids
  end

  defp plane_only?(supervisor) do
    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    AgentLink.Relay.Agent not in ids and AgentLink.Relay.Agent.Supervisor not in ids
  end

  defp crash_until_down(supervisor, ref, attempts) when attempts > 0 do
    crash_relay()

    receive do
      {:DOWN, ^ref, :process, ^supervisor, _} -> :ok
    after
      200 ->
        assert is_pid(wait_relay())
        crash_until_down(supervisor, ref, attempts - 1)
    end
  end

  defp crash_until_down(_supervisor, _ref, 0), do: flunk("agent relay supervisor did not stop")

  defp crash_relay do
    pid = wait_relay()
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  defp wait_relay(attempts \\ 50) do
    case Process.whereis(AgentLink.Relay.Agent) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(20)
        wait_relay(attempts - 1)

      nil ->
        flunk("agent relay did not start")
    end
  end

  defp connect_root do
    path =
      Path.join(System.tmp_dir!(), "agentlink-connect-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp write_connect_config!(root, map) do
    File.write!(Path.join(root, "config"), Jason.encode!(map))
  end

  defp write_connect_token!(root, body, mode \\ 0o600) do
    path = Path.join(root, "token")
    File.rm(path)
    File.write!(path, body)
    File.chmod!(path, mode)
  end

  defp put_connect(root, env, plane, target, token) do
    Application.put_env(:agent_link, :mode, :connect)
    Application.put_env(:agent_link, :config_root, root)
    Application.put_env(:agent_link, :config_env, env)
    Application.put_env(:agent_link, :connect_plane, plane)
    Application.put_env(:agent_link, :connect_target, target)
    Application.put_env(:agent_link, :connect_token, token)

    Application.put_env(
      :agent_link,
      :connect_transport,
      AgentLink.ApplicationTest.ObservedTransport
    )

    Application.put_env(:agent_link, :connect_stdio, AgentLink.ApplicationTest.ObservedStdio)
    Application.put_env(:agent_link, :connect_observer, self())

    Application.put_env(
      :agent_link,
      :link_path,
      Path.join(root, "missing-#{System.unique_integer([:positive])}.json")
    )
  end

  defp connect_client!(sup) do
    [{AgentLink.Relay.Client, client, :worker, [AgentLink.Relay.Client]}] =
      Supervisor.which_children(sup)

    client
  end

  defp connect_dial! do
    assert_receive {:connect_dial, transport, dial}
    {transport, dial}
  end

  defp connect_stdio! do
    assert_receive {:connect_stdio, stdio}
    stdio
  end

  defp assert_runtime_select(name) do
    assert_receive {:connect_plane,
                    %{"id" => "agentlink:runtime/select", "params" => %{"name" => ^name}}}
  end

  defp deliver_runtimes(transport, names) do
    rows = Enum.map(names, &%{"name" => &1, "label" => &1, "program" => "opencode"})

    message = %{
      "jsonrpc" => "2.0",
      "id" => "agentlink:runtime/list",
      "result" => %{"runtimes" => rows}
    }

    assert :ok = AgentLink.FakeTransport.deliver(transport, message)
  end

  defp write_link do
    path =
      Path.join(
        System.tmp_dir!(),
        "agentlink-app-link-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent","command":"agentlink-fake","args":["acp"]})
    )

    Application.put_env(:agent_link, :link_path, path)
    path
  end

  defp restore_link(nil), do: Application.delete_env(:agent_link, :link_path)
  defp restore_link(path), do: Application.put_env(:agent_link, :link_path, path)
end
