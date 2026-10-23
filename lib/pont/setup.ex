defmodule Pont.Setup do
  @moduledoc """
  Prints the instructions from the access policy, then reports when a sidecar
  connects or is rejected. The policy decides how a token is created.
  """

  @doc "Ask the access policy to install credentials, and show its instructions. Tests skip this."
  def prepare do
    if Mix.env() == :test do
      :ok
    else
      case Pont.Access.prepare() do
        {:ok, text} -> IO.puts(text)
        {:error, text} -> IO.puts(:stderr, text)
      end
    end
  end

  @doc "A sidecar registered. The watcher prints it when this plane is running."
  def connected(name, label) when is_binary(name) do
    notify({:connected, name, label})
  end

  @doc "A sidecar presented the wrong master token."
  def rejected, do: notify(:rejected)

  defp notify(message) do
    if pid = Process.whereis(Pont.Setup.Watch), do: send(pid, message)
    :ok
  end
end

defmodule Pont.Setup.Watch do
  @moduledoc """
  Prints sidecar success and auth failure. Started with the plane.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_info({:connected, name, label}, state) do
    IO.puts("Sidecar connected: #{name} (#{label}).")
    {:noreply, state}
  end

  def handle_info(:rejected, state) do
    IO.puts(:stderr, "A sidecar was rejected. The master token did not match.")
    {:noreply, state}
  end
end