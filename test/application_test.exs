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
  end

  test "all mode starts both" do
    if pid = Process.whereis(Pont.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end
    Application.put_env(:pont, :mode, :all)
    Application.put_env(:pont, :port, 18_097)
    write_link()
    assert {:ok, _pid} = Pont.Application.start(:normal, [])
    assert_receive {:harness_opened, _agent, _cwd}
    assert Process.whereis(Pont.Plane)
    assert Process.whereis(Pont.Sidecar)
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
