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
  def connected(name, label) when is_binary(name), do: Pont.Setup.Watch.connected(name, label)

  @doc "A sidecar presented the wrong master token."
  def rejected, do: Pont.Setup.Watch.rejected()
end

defmodule Pont.Setup.Watch do
  @moduledoc """
  Prints sidecar success and auth failure. Started with the plane.
  """

  use GenServer

  defstruct []

  @doc "Own the printer. Started with the plane."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @doc "A sidecar registered. Print its link name and machine."
  def connected(name, label) when is_binary(name), do: notify({:connected, name, label})

  @doc "A sidecar presented the wrong master token. Print the rejection."
  def rejected, do: notify(:rejected)

  @impl true
  def handle_info({:connected, name, label}, %__MODULE__{} = state) do
    IO.puts("Sidecar connected: #{name} (#{label}).")
    {:noreply, state}
  end

  def handle_info(:rejected, %__MODULE__{} = state) do
    IO.puts(:stderr, "A sidecar was rejected. The master token did not match.")
    {:noreply, state}
  end

  defp notify(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
    :ok
  end
end