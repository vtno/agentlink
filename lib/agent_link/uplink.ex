defmodule AgentLink.Uplink do
  @moduledoc """
  Dials the plane's agent socket through `AgentLink.Transport`. Outbound
  objects are maps. `AgentLink.Transport.WebSocket` is the Mint client.
  Nothing here calls the plane process directly.

  The first object on every dial is `agentlink.uplink`. It carries this VM's
  relay instance, so the plane can release this relay's previous socket when
  this process dials again. That hello is the transport preface: the preface
  is sent before the outbox, including on a dial the transport starts itself.

  A close that means this name is already in use logs the clash and waits
  until the link name or plane URL changes. A close that means the instance
  id is too long logs the error and does not redial until restart. Bad-name
  and not-allowed closes also park until the name or plane URL changes or
  the relay restarts. Parking calls `hold/1`. A non-parking close refreshes
  the preface and the next dial URL and leaves the backoff timer. `:watch`
  calls `reconnect/2` when the stored link still differs, except an instance
  id that is too long. The codes and reasons are shared in
  `AgentLink.AgentSocketProtocol`.
  """

  use GenServer
  require Logger

  defstruct [
    :owner,
    :transport,
    :transport_pid,
    :link,
    :replaced,
    watch_interval: 1_000,
    rejection: nil
  ]

  @doc """
  Dial the plane's agent socket. A remote relay never calls the plane process directly.

  `:owner` receives `{:from_plane, message}`. `:transport` is the
  `AgentLink.Transport` module, default `AgentLink.Transport.WebSocket`.
  `:transport_opts` are passed through to that module. This process sets
  `:owner`, `:url`, `:default_path`, and `:preface`. `:watch_interval` is
  milliseconds between reads of the link file, default 1_000. `nil` does not
  schedule those reads. `:link` is an `AgentLink.Link` from the caller. When
  `:link` is set, `init/1` does not read the link file. When `:link` is
  omitted, `init/1` calls `AgentLink.Link.read/1`. A watch and a non-parking
  close still call `AgentLink.Link.read/1`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    case initial_link(opts) do
      {:ok, link} ->
        module = Keyword.get(opts, :transport, AgentLink.Transport.WebSocket)

        transport_opts =
          opts
          |> Keyword.get(:transport_opts, [])
          |> Keyword.merge(
            owner: self(),
            url: link.plane_url,
            default_path: "/agent",
            preface: uplink_hello(link)
          )

        case module.start_link(transport_opts) do
          {:ok, pid} ->
            state = %__MODULE__{
              owner: Keyword.fetch!(opts, :owner),
              transport: module,
              transport_pid: pid,
              link: link,
              watch_interval: Keyword.get(opts, :watch_interval, 1_000)
            }

            schedule_watch(state)
            {:ok, state}

          {:error, reason} ->
            {:stop, reason}

          :ignore ->
            {:stop, :ignore}
        end

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @doc "One ACP object toward the plane. Queued if the socket is down."
  def send_message(message) when is_map(message) do
    GenServer.cast(__MODULE__, {:send, message})
  end

  @impl true
  def handle_cast({:send, message}, %__MODULE__{} = state) do
    state.transport.send_message(state.transport_pid, message)
    {:noreply, state}
  end

  @impl true
  def handle_info(:watch, %__MODULE__{} = state) do
    case read_link() do
      {:ok, link} ->
        state = maybe_redial(state, link)
        schedule_watch(state)
        {:noreply, state}

      {:stop, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:from_plane, message}, %__MODULE__{} = state) when is_map(message) do
    send(state.owner, {:from_plane, message})
    {:noreply, state}
  end

  # `reconnect/2` already closed this socket and did not report it. A close
  # that was in flight belongs to that socket. Parking would cancel the dial
  # the link change just queued, and the file would then match `link`.
  def handle_info({:transport_closed, code, reason}, %__MODULE__{replaced: replaced} = state)
      when not is_nil(replaced) and is_integer(code) and is_binary(reason) do
    {:noreply, state}
  end

  def handle_info({:transport_closed, code, reason}, %__MODULE__{} = state)
      when is_integer(code) and is_binary(reason) do
    case AgentLink.AgentSocketProtocol.rejection(code) do
      nil ->
        # The transport retries on its timer with the preface and URL from
        # the last dial. Read now so that retry sees a missing file, a new
        # hello, or a new plane URL. The timer stays: this clause does not
        # call `reconnect/2`.
        case read_link() do
          {:ok, link} ->
            state =
              if link == state.link do
                state
              else
                :ok = state.transport.preface(state.transport_pid, uplink_hello(link))

                if link.plane_url != state.link.plane_url do
                  :ok = state.transport.url(state.transport_pid, link.plane_url)
                end

                %{state | link: link}
              end

            {:noreply, state}

          {:stop, reason} ->
            {:stop, reason, state}
        end

      rejection ->
        log_rejection(state, rejection, reason)
        :ok = state.transport.hold(state.transport_pid)
        {:noreply, %{state | rejection: rejection}}
    end
  end

  def handle_info({:replaced, ref}, %__MODULE__{replaced: ref} = state) do
    {:noreply, %{state | replaced: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The socket scheme, HTTP scheme, host, port, and path for a plane URL.
  `wss` and `https` use TLS. A missing port is 443 for those and 80 otherwise.
  A missing path is `/agent`. `AgentLink.Transport.endpoint/2` is the parser.
  """
  def endpoint(url), do: AgentLink.Transport.endpoint(url, "/agent")

  defp schedule_watch(%__MODULE__{watch_interval: nil}), do: :ok

  defp schedule_watch(%__MODULE__{watch_interval: interval}) do
    Process.send_after(self(), :watch, interval)
    :ok
  end

  defp initial_link(opts) do
    case Keyword.fetch(opts, :link) do
      {:ok, %AgentLink.Link{} = link} -> {:ok, link}
      :error -> read_link()
    end
  end

  defp read_link do
    case AgentLink.Link.read() do
      {:ok, link} ->
        {:ok, link}

      {:error, message} ->
        Logger.error(message)
        {:stop, {:shutdown, message}}
    end
  end

  # The instance id is not in the link file. A new name or plane URL would dial the same id.
  defp maybe_redial(%__MODULE__{rejection: :instance_too_long} = state, _link), do: state

  defp maybe_redial(%__MODULE__{rejection: rejection} = state, link) when not is_nil(rejection) do
    if link_target_changed?(state.link, link) do
      Logger.info("agent link changed, redialing as #{link.name}")
      redial(%{state | rejection: nil}, link)
    else
      state
    end
  end

  defp maybe_redial(%__MODULE__{} = state, link) do
    if link != state.link do
      Logger.info("agent link changed, redialing as #{link.name}")
      redial(state, link)
    else
      state
    end
  end

  defp link_target_changed?(current, link) do
    link.name != current.name or link.plane_url != current.plane_url
  end

  defp redial(%__MODULE__{} = state, link) do
    # Preface first. A close already in the transport mailbox is reported
    # during that call, ahead of the mark, and is dropped. The mark goes out
    # before the dial, so a close from the socket this call opens stays
    # behind it and still parks.
    :ok = state.transport.preface(state.transport_pid, uplink_hello(link))
    ref = make_ref()
    send(self(), {:replaced, ref})
    :ok = state.transport.reconnect(state.transport_pid, link.plane_url)
    %{state | link: link, replaced: ref}
  end

  defp log_rejection(%__MODULE__{} = state, rejection, reason) do
    detail =
      if is_binary(reason) and reason != "" do
        reason
      else
        AgentLink.AgentSocketProtocol.reason(rejection, state.link.name)
      end

    action =
      case rejection do
        :name_taken ->
          "Another relay is already connected with this name. " <>
            "Stop the other relay and restart this one, or change name in #{AgentLink.Paths.link()}. "

        :bad_name ->
          "Fix name in #{AgentLink.Paths.link()} and restart this relay, or change name or plane_url. "

        :not_allowed ->
          "Ask the plane operator to allow this uplink, then restart this relay, " <>
            "or change name or plane_url in #{AgentLink.Paths.link()}. "

        :instance_too_long ->
          "Fix the relay instance id and restart this relay. "
      end

    # The instance id is not in the link file. Changing the target cannot fix it.
    wait =
      if rejection == :instance_too_long,
        do: "This relay will not reconnect until restart",
        else: "This relay will not reconnect until name or plane_url changes, or restart"

    Logger.error("uplink rejected name=#{state.link.name} #{detail}. " <> action <> wait)
  end

  defp uplink_hello(link) do
    %{
      "jsonrpc" => "2.0",
      "method" => "agentlink.uplink",
      "params" => %{
        "name" => link.name,
        "label" => link.label,
        "program" => link.program,
        "instance" => relay_instance()
      }
    }
  end

  # One id per VM. A new `AgentLink.Uplink` process in this BEAM is still this relay.
  # A second OS process has a different id and cannot take the name.
  defp relay_instance do
    key = {__MODULE__, :instance}

    case :persistent_term.get(key, nil) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        :persistent_term.put(key, id)
        id
    end
  end
end
