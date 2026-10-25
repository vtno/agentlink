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
  # Stock relays send 16 random bytes as unpadded base64url, which is 22 bytes.
  # 128 leaves room for a longer token without storing an unbounded id.
  @max_instance_bytes 128

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

  An instance id longer than #{@max_instance_bytes} bytes is rejected. That
  hello does not change the existing row.
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

  @doc "The longest relay instance id this plane will accept, in bytes."
  def max_instance_bytes, do: @max_instance_bytes

  @doc "The longest link name this plane will accept, in characters."
  def max_name_chars, do: @max_name_chars

  @doc "An uplink said hello. The access policy accepts this subject. A live holder of the name keeps the socket."
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
          {:reply, :ok, state}

        [{^name, %Pont.Registry.Uplink{pid: holder} = current}] ->
          cond do
            Process.alive?(holder) and same_relay?(current, uplink) ->
              Logger.info("uplink reconnect name=#{name} the same relay dialed again")
              send(holder, :superseded)
              {:reply, :ok, remember(drop_pid(state, holder), pid, uplink)}

            Process.alive?(holder) ->
              Logger.warning(
                "uplink rejected name=#{name} another uplink is already connected with this name"
              )

              {:reply, {:error, {:name_taken, name}}, state}

            true ->
              Logger.warning("uplink stale name=#{name} the previous holder was already dead")
              {:reply, :ok, remember(drop_pid(state, holder), pid, uplink)}
          end

        [] ->
          {:reply, :ok, remember(state, pid, uplink)}
      end
    else
      {:error, :instance_too_long} ->
        Logger.warning(
          "uplink rejected name=#{String.trim(uplink.name)} instance id is too long; max is #{@max_instance_bytes} bytes"
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
      {:error, "link name must be a short slug"}
    end
  end

  defp normalize_name(_), do: {:error, "link name must be a short slug"}

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
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text when byte_size(text) <= @max_instance_bytes ->
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
