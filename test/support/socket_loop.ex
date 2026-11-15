defmodule AgentLink.SocketLoop do
  @moduledoc false

  # Runs WebSock callbacks in a process the test can exit. Bandit is not involved.
  def start(module, arg) do
    parent = self()

    pid =
      spawn_link(fn ->
        case module.init(arg) do
          {:ok, state} ->
            send(parent, {:socket_loop, self(), :ready, state})
            loop(module, parent, state)

          other ->
            send(parent, {:socket_loop, self(), :init, other})
        end
      end)

    ref = Process.monitor(pid)

    receive do
      {:socket_loop, ^pid, :ready, state} ->
        Process.demonitor(ref, [:flush])
        {pid, state}

      {:socket_loop, ^pid, :init, other} ->
        Process.demonitor(ref, [:flush])
        raise "socket init returned #{inspect(other)}"

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "socket loop exited: #{inspect(reason)}"
    end
  end

  def state(pid) do
    ref = Process.monitor(pid)
    send(pid, {:socket_loop_state, self()})

    receive do
      {:socket_loop, ^pid, :state, state} ->
        Process.demonitor(ref, [:flush])
        state

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "socket loop down: #{inspect(reason)}"
    end
  end

  defp loop(module, parent, state) do
    receive do
      {:socket_loop_state, from} ->
        send(from, {:socket_loop, self(), :state, state})
        loop(module, parent, state)

      {:in, frame} ->
        step(module, parent, module.handle_in(frame, state))

      {:control, frame} ->
        step(module, parent, module.handle_control(frame, state))

      message ->
        step(module, parent, module.handle_info(message, state))
    end
  end

  defp step(module, parent, {:ok, state}), do: loop(module, parent, state)

  defp step(module, parent, {:push, frames, state}) do
    send(parent, {:socket_loop, self(), :push, frames})
    loop(module, parent, state)
  end

  defp step(module, _parent, {:stop, reason, state}) do
    module.terminate(reason, state)
  end

  defp step(module, _parent, {:stop, reason, _close, state}) do
    module.terminate(reason, state)
  end
end
