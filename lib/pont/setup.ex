defmodule Pont.Setup do
  @moduledoc """
  Prints the instructions from the access policy. The policy decides how a token is created.
  """

  @doc "Ask the access policy to install credentials, and show its instructions. Tests skip this."
  def prepare do
    if Mix.env() == :test do
      :ok
    else
      case Pont.Access.prepare() do
        {:ok, text} ->
          IO.puts(text)
          :ok

        {:error, text} ->
          IO.puts(:stderr, text)
          {:error, text}
      end
    end
  end
end

defmodule Pont.Setup.Watch do
  @moduledoc """
  Prints an uplink hello and a refused dial. Started with the plane.
  """

  use GenServer

  defstruct []

  @doc "Own the printer. Started with the plane."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @doc "An uplink said hello. Print its link name and machine."
  def connected(name, label) when is_binary(name), do: notify({:connected, name, label})

  @doc "A dial was refused. Print the reason."
  def rejected(reason) when is_binary(reason), do: notify({:rejected, reason})

  @impl true
  def handle_info({:connected, name, label}, %__MODULE__{} = state) do
    IO.puts("Uplink connected: #{name} (#{label}).")
    {:noreply, state}
  end

  def handle_info({:rejected, reason}, %__MODULE__{} = state) do
    IO.puts(:stderr, "An uplink was rejected. #{reason}")
    {:noreply, state}
  end

  defp notify(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
    :ok
  end
end