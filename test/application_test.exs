defmodule Pont.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:pont, :harness_listener, self())
    previous = {Application.get_env(:pont, :mode), Application.get_env(:pont, :port)}

    on_exit(fn ->
      Application.delete_env(:pont, :harness_listener)
      {mode, port} = previous
      if mode, do: Application.put_env(:pont, :mode, mode)
      if port, do: Application.put_env(:pont, :port, port)

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

  test "agent mode starts only the sidecar" do
    if pid = Process.whereis(Pont.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end
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
    assert {:ok, _pid} = Pont.Application.start(:normal, [])
    assert_receive {:harness_opened, _agent, _cwd}
    assert Process.whereis(Pont.Plane)
    assert Process.whereis(Pont.Sidecar)
  end
end
