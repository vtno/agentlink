defmodule Pont.Registry.Uplink do
  @moduledoc """
  The row recorded after an uplink says hello. `name` comes from the link. `label` is the machine.
  `program` is the agent product name, not the `Pont.Agent` module. `instance` identifies the
  relay VM. A later hello with the same instance is that relay dialing again. An id longer
  than the plane's maximum is rejected.
  """

  defstruct [:name, :label, :program, :pid, :instance, :connected_at]
end

defmodule Pont.Registry do
  # Link names are slugs, and Link.slug/1 cuts one to this length. The plane
  # rejects a longer name instead of storing an unbounded id.
  @max_name_chars 40
  @name_regex ~r/^[a-z0-9][a-z0-9_-]{0,#{@max_name_chars - 1}}$/

  @moduledoc """
  Live uplinks. One row is one uplink that has said hello.
  The socket is the source of truth.

  The first live socket to claim a name keeps it. A later hello from that
  same relay releases the previous socket and the new one keeps the name.
  A later hello from another relay is rejected, and the existing row is left
  alone. Register calls run one at a time, so two hellos at the same moment
  still have one winner. A row whose pid is already dead is stale: the socket
  is gone, and the new hello takes the name. When the holder process exits,
  the name is free.

  An instance id above the byte limit in `Pont.SocketProtocol.max_instance_bytes/0` is
  rejected. That hello does not change the existing row.
  """

  use GenServer
  require Logger

  @table :pont_runtimes

  defstruct pids: %{}

  @doc "Own the ETS table of who is dialed in."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %__MODULE__{}}
  end

  @doc "The longest link name this plane will accept, in characters."
  def max_name_chars, do: @max_name_chars

  @doc """
  Register an uplink hello under its normalized name. A live holder keeps the name.
  Returns `{:ok, name}` or `{:error, rejection}` from the shared hello protocol.
  """
  def register(pid, %Pont.Registry.Uplink{} = uplink, %Pont.Access.Subject{} = subject)
      when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, pid, uplink, subject})
  end

  @impl true
  def handle_call(
        {:register, pid, %Pont.Registry.Uplink{} = uplink, subject},
        _from,
        %__MODULE__{} = state
      ) do
    with {:ok, name} <- normalize_name(uplink.name),
         :ok <- Pont.Access.claim(subject, name),
         {:ok, instance} <- instance_id(uplink.instance) do
      uplink = %Pont.Registry.Uplink{
        name: name,
        label: clip(uplink.label, name),
        program: clip(uplink.program, "opencode"),
        instance: instance,
        pid: pid,
        connected_at: System.system_time(:second)
      }

      case :ets.lookup(@table, name) do
        [{^name, %Pont.Registry.Uplink{pid: ^pid}}] ->
          {:reply, {:ok, name}, state}

        [{^name, %Pont.Registry.Uplink{pid: holder} = current}] ->
          cond do
            Process.alive?(holder) and same_relay?(current, uplink) ->
              Logger.info("uplink reconnect name=#{name} the same relay dialed again")
              send(holder, :superseded)
              {:reply, {:ok, name}, remember(drop_pid(state, holder), pid, uplink)}

            Process.alive?(holder) ->
              Logger.warning(
                "uplink rejected name=#{name} another uplink is already connected with this name"
              )

              {:reply, {:error, :name_taken}, state}

            true ->
              Logger.warning("uplink stale name=#{name} the previous holder was already dead")
              {:reply, {:ok, name}, remember(drop_pid(state, holder), pid, uplink)}
          end

        [] ->
          {:reply, {:ok, name}, remember(state, pid, uplink)}
      end
    else
      {:error, :instance_too_long} ->
        Logger.warning(
          "uplink rejected name=#{String.trim(uplink.name)} #{Pont.SocketProtocol.reason(:instance_too_long)}"
        )

        {:reply, {:error, :instance_too_long}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %__MODULE__{} = state) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        {:noreply, state}

      {{_ref, name}, pids} ->
        case :ets.lookup(@table, name) do
          [{^name, %Pont.Registry.Uplink{pid: ^pid}}] ->
            :ets.delete(@table, name)
            Logger.warning("runtime down name=#{name} #{inspect(reason)}")
            Pont.Plane.runtime_down(name)

          _ ->
            :ok
        end

        {:noreply, %{state | pids: pids}}
    end
  end

  @doc "The uplinks this subject may use."
  def allowed(%Pont.Access.Subject{} = subject) do
    Enum.filter(list(), &Pont.Access.allowed?(subject, &1["name"]))
  end

  @doc "The uplinks currently dialed in. `name` is what a client selects."
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, %Pont.Registry.Uplink{} = uplink} ->
      %{
        "name" => uplink.name,
        "label" => uplink.label,
        "program" => uplink.program,
        "connected_at" => uplink.connected_at
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc "The agent socket pid registered under this link name, or nil."
  def pid(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, %Pont.Registry.Uplink{pid: pid}}] -> pid
      [] -> nil
    end
  end

  defp remember(%__MODULE__{} = state, pid, %Pont.Registry.Uplink{} = uplink) do
    state = drop_pid(state, pid)
    ref = Process.monitor(pid)
    :ets.insert(@table, {uplink.name, uplink})

    Logger.info(
      "uplink registered name=#{uplink.name} label=#{uplink.label} program=#{uplink.program}"
    )

    Pont.Setup.Watch.connected(uplink.name, uplink.label)
    Pont.Plane.runtime_reset(uplink.name)
    %{state | pids: Map.put(state.pids, pid, {ref, uplink.name})}
  end

  defp drop_pid(%__MODULE__{} = state, pid) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        state

      {{ref, name}, pids} ->
        Process.demonitor(ref, [:flush])

        case :ets.lookup(@table, name) do
          [{^name, %Pont.Registry.Uplink{pid: ^pid}}] -> :ets.delete(@table, name)
          _ -> :ok
        end

        %{state | pids: pids}
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name = String.trim(name)

    if String.match?(name, @name_regex) do
      {:ok, name}
    else
      {:error, :bad_name}
    end
  end

  defp normalize_name(_), do: {:error, :bad_name}

  defp clip(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      text -> String.slice(text, 0, 80)
    end
  end

  defp clip(_value, fallback), do: fallback

  # Empty and missing ids never match, including nil with nil. A present id
  # is kept whole. An id over the maximum is an error, not a missing id.
  defp instance_id(value) when is_binary(value) do
    max = Pont.SocketProtocol.max_instance_bytes()

    case String.trim(value) do
      "" ->
        {:ok, nil}

      text when byte_size(text) <= max ->
        {:ok, text}

      _text ->
        {:error, :instance_too_long}
    end
  end

  defp instance_id(_value), do: {:ok, nil}

  defp same_relay?(%Pont.Registry.Uplink{instance: id}, %Pont.Registry.Uplink{instance: id})
       when is_binary(id),
       do: true

  defp same_relay?(_current, _uplink), do: false
end
