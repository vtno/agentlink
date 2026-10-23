defmodule Pont.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:pont, :harness_listener, self())
    previous = {Application.get_env(:pont, :mode), Application.get_env(:pont, :port), Application.get_env(:pont, :link_path)}

    on_exit(fn ->
      Application.delete_env(:pont, :harness_listener)
      {mode, port, link_path} = previous
      if mode, do: Application.put_env(:pont, :mode, mode)
      if port, do: Application.put_env(:pont, :port, port)
      restore_link(link_path)

      if pid = Process.whereis(Pont.Supervisor) do
        Process.exit(pid, :kill)
        Process.sleep(50)
      end
    end)

    :ok
  end

  test "plane mode does not start a sidecar" do
    Application.put_env(:pont, :mode, :plane)
    Application.put_env(:pont, :port, 18_096)
    assert {:ok, _pid} = Pont.Application.start(:normal, [])
    assert Process.whereis(Pont.Plane)
    assert Process.whereis(Pont.Registry)
    assert Process.whereis(Pont.Plane.Supervisor)
    refute Process.whereis(Pont.Sidecar)
  end

  test "agent mode stops when the link file is missing" do
    Application.put_env(:pont, :mode, :agent)
    Application.put_env(:pont, :link_path, "/tmp/pont-missing-#{System.unique_integer([:positive])}.json")

    assert {:error, message} = Pont.Application.start(:normal, [])
    assert message =~ "No link file"
    refute Process.whereis(Pont.Sidecar)
  end

  test "agent mode starts only the sidecar" do
    if pid = Process.whereis(Pont.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end

    write_link()
    Application.put_env(:pont, :mode, :agent)
    assert {:ok, _pid} = Pont.Application.start(:normal, [])
    assert_receive {:harness_opened, _agent, _cwd}
    assert Process.whereis(Pont.Sidecar)
    refute Process.whereis(Pont.Plane)
    refute Process.whereis(Pont.Plane.Supervisor)
  end

  test "all mode starts both" do
    start_all(18_097)
    assert Process.whereis(Pont.Plane)
    assert Process.whereis(Pont.Sidecar)
    assert Process.whereis(Pont.Sidecar.Supervisor)
    assert plane_only?(Pont.Plane.Supervisor)
  end

  test "a sidecar crash loop leaves the plane up" do
    start_all(18_098)
    supervisor = Process.whereis(Pont.Sidecar.Supervisor)
    supervisor_ref = Process.monitor(supervisor)

    crash_until_down(supervisor, supervisor_ref, 20)
    Process.sleep(50)
    assert Process.alive?(Process.whereis(Pont.Plane))
    assert Process.alive?(Process.whereis(Pont.Registry))
    assert Process.alive?(Process.whereis(Pont.Plane.Supervisor))
    assert Process.alive?(Process.whereis(Pont.Supervisor))
    assert plane_only?(Pont.Plane.Supervisor)
    refute Process.whereis(Pont.Sidecar)
    refute Process.whereis(Pont.Sidecar.Supervisor)
  end

  defp start_all(port) do
    if pid = Process.whereis(Pont.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end

    Application.put_env(:pont, :mode, :all)
    Application.put_env(:pont, :port, port)
    write_link()
    assert {:ok, _pid} = Pont.Application.start(:normal, [])
    assert_receive {:harness_opened, _agent, _cwd}
  end

  defp plane_only?(supervisor) do
    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    Pont.Sidecar not in ids and Pont.Sidecar.Supervisor not in ids
  end

  defp crash_until_down(supervisor, ref, attempts) when attempts > 0 do
    crash_sidecar()

    receive do
      {:DOWN, ^ref, :process, ^supervisor, _} -> :ok
    after
      200 ->
        assert is_pid(wait_sidecar())
        crash_until_down(supervisor, ref, attempts - 1)
    end
  end

  defp crash_until_down(_supervisor, _ref, 0), do: flunk("sidecar supervisor did not stop")

  defp crash_sidecar do
    pid = wait_sidecar()
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  defp wait_sidecar(attempts \\ 50) do
    case Process.whereis(Pont.Sidecar) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(20)
        wait_sidecar(attempts - 1)

      nil ->
        flunk("sidecar did not start")
    end
  end

  defp write_link do
    path = Path.join(System.tmp_dir!(), "pont-app-link-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"name":"opencode","label":"this machine","program":"opencode","plane_url":"ws://127.0.0.1:1/agent"}))
    Application.put_env(:pont, :link_path, path)
    path
  end

  defp restore_link(nil), do: Application.delete_env(:pont, :link_path)
  defp restore_link(path), do: Application.put_env(:pont, :link_path, path)
end
