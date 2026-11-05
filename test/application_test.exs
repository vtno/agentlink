defmodule AgentLink.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:agent_link, :agent_listener, self())

    previous =
      {Application.get_env(:agent_link, :mode), Application.get_env(:agent_link, :port),
       Application.get_env(:agent_link, :link_path)}

    on_exit(fn ->
      Application.delete_env(:agent_link, :agent_listener)
      {mode, port, link_path} = previous
      if mode, do: Application.put_env(:agent_link, :mode, mode)
      if port, do: Application.put_env(:agent_link, :port, port)
      restore_link(link_path)

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
    assert {:ok, _pid} = AgentLink.Application.start(:normal, [])
    assert Process.whereis(AgentLink.Plane)
    assert Process.whereis(AgentLink.Plane.Sessions)
    assert Process.whereis(AgentLink.Registry)
    assert Process.whereis(AgentLink.Plane.Supervisor)
    refute Process.whereis(AgentLink.Relay.Agent)
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

  test "relay mode starts only the relay" do
    if pid = Process.whereis(AgentLink.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end

    write_link()
    Application.put_env(:agent_link, :mode, :relay)
    assert {:ok, _pid} = AgentLink.Application.start(:normal, [])
    assert_receive {:agent_opened, _agent, _cwd}
    assert Process.whereis(AgentLink.Relay.Agent)
    refute Process.whereis(AgentLink.Plane)
    refute Process.whereis(AgentLink.Plane.Sessions)
    refute Process.whereis(AgentLink.Plane.Supervisor)
  end

  test "all mode starts both" do
    start_all(18_097)
    assert Process.whereis(AgentLink.Plane)
    assert Process.whereis(AgentLink.Relay.Agent)
    assert Process.whereis(AgentLink.Relay.Agent.Supervisor)
    assert plane_only?(AgentLink.Plane.Supervisor)
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
    assert_receive {:agent_opened, _agent, _cwd}
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

  defp write_link do
    path =
      Path.join(
        System.tmp_dir!(),
        "agentlink-app-link-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent"})
    )

    Application.put_env(:agent_link, :link_path, path)
    path
  end

  defp restore_link(nil), do: Application.delete_env(:agent_link, :link_path)
  defp restore_link(path), do: Application.put_env(:agent_link, :link_path, path)
end
