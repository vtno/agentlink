defmodule AgentLink.FakeScheduler do
  @moduledoc false

  # Records `send_after/3` and delivers the message when the test calls `fire/1`.
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def send_after(destination, message, delay) do
    ref = make_ref()
    Agent.update(__MODULE__, &Map.put(&1, ref, {destination, message, delay}))
    ref
  end

  def cancel_timer(ref) do
    Agent.get_and_update(__MODULE__, &Map.pop(&1, ref, nil))
    :ok
  end

  def scheduled(ref), do: Agent.get(__MODULE__, &Map.get(&1, ref))

  def fire(ref) do
    {destination, message, _delay} = Agent.get_and_update(__MODULE__, &Map.pop(&1, ref))
    send(destination, message)
    :ok
  end
end
