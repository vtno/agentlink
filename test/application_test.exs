defmodule Acp.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:acp, :harness_listener, self())
    previous = {Application.get_env(:acp, :mode), Application.get_env(:acp, :port)}

    on_exit(fn ->
      Application.delete_env(:acp, :harness_listener)
      {mode, port} = previous
      if mode, do: Application.put_env(:acp, :mode, mode)
      if port, do: Application.put_env(:acp, :port, port)

      if pid = Process.whereis(Acp.Supervisor) do
        Process.exit(pid, :kill)
        Process.sleep(50)
      end
    end)

    :ok
  end

  test "plane mode does not start a sidecar" do
    Application.put_env(:acp, :mode, :plane)
    Application.put_env(:acp, :port, 18_096)
    assert {:ok, _pid} = Acp.Application.start(:normal, [])
    assert Process.whereis(Acp.Plane)
    assert Process.whereis(Acp.Registry)
    refute Process.whereis(Acp.Sidecar)
  end

  test "agent mode starts only the sidecar" do
    if pid = Process.whereis(Acp.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end
    Application.put_env(:acp, :mode, :agent)
    assert {:ok, _pid} = Acp.Application.start(:normal, [])
    assert_receive {:harness_opened, _agent, _cwd}
    assert Process.whereis(Acp.Sidecar)
    refute Process.whereis(Acp.Plane)
  end

  test "all mode starts both" do
    if pid = Process.whereis(Acp.Supervisor) do
      Process.exit(pid, :kill)
      Process.sleep(50)
    end
    Application.put_env(:acp, :mode, :all)
    Application.put_env(:acp, :port, 18_097)
    assert {:ok, _pid} = Acp.Application.start(:normal, [])
    assert_receive {:harness_opened, _agent, _cwd}
    assert Process.whereis(Acp.Plane)
    assert Process.whereis(Acp.Sidecar)
  end
end
