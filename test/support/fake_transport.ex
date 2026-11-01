defmodule AgentLink.FakeTransport do
  @moduledoc """
  In-process `AgentLink.Transport` for tests. No socket.

  `deliver/2` is a decoded map from the plane. `disconnect/3` is a peer close.
  `sent/1` is what has been written to the plane, oldest first, not what is
  still queued. Start with `accept: false` when the plane should refuse the
  dial. `allow/1` makes the next dial succeed and does not dial by itself.
  `close_next/3` makes the next `reconnect/2` open and then close before
  that call returns.
  """

  @behaviour AgentLink.Transport
  use GenServer

  # Same floor as the Mint client, so a refused dial cannot tight-loop.
  @min_backoff 50

  defstruct [
    :owner,
    :url,
    :headers,
    :backoff,
    :default_path,
    :preface,
    :timer,
    :connect_token,
    outbox: [],
    sent: [],
    held: false,
    up: false,
    accept: true,
    close_next: nil
  ]

  @impl true
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      owner: Keyword.fetch!(opts, :owner),
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.get_lazy(opts, :headers, &AgentLink.Auth.headers/0),
      backoff: retry_delay(Keyword.get(opts, :backoff, 500)),
      default_path: Keyword.get(opts, :default_path, "/agent"),
      preface: Keyword.get(opts, :preface),
      accept: Keyword.get(opts, :accept, true)
    }

    {:ok, request_connect(state, 0)}
  end

  @impl true
  def send_message(server, message) when is_map(message) do
    GenServer.cast(server, {:send, message})
    :ok
  end

  @impl true
  def handle_cast({:send, message}, state) do
    {:noreply, transmit(message, state)}
  end

  @impl true
  def hold(server), do: GenServer.call(server, :hold)

  @impl true
  def reconnect(server, url) when is_binary(url), do: GenServer.call(server, {:reconnect, url})

  @doc """
  Send `message` before the outbox on every dial, including a dial this
  process starts itself. `nil` clears it. An open socket is left as it is.
  """
  @impl true
  def preface(server, message) when is_map(message) or is_nil(message) do
    GenServer.call(server, {:preface, message})
  end

  @doc "A decoded object from the plane, or `:closed` when the socket is down."
  def deliver(server, message) when is_map(message) do
    GenServer.call(server, {:deliver, message})
  end

  @doc "Peer close. The owner receives `{:transport_closed, code, reason}`."
  def disconnect(server, code, reason \\ "") when is_integer(code) and is_binary(reason) do
    GenServer.call(server, {:disconnect, code, reason})
  end

  @doc "Objects written to the plane, oldest first."
  def sent(server), do: GenServer.call(server, :sent)

  @doc "The next dial reaches the plane. Does not dial by itself."
  def allow(server), do: GenServer.call(server, :allow)

  @doc """
  The next `reconnect/2` opens, writes the preface, and the plane closes it
  before that call returns.
  """
  def close_next(server, code, reason \\ "") when is_integer(code) and is_binary(reason) do
    GenServer.call(server, {:close_next, code, reason})
  end

  @impl true
  def handle_call(:hold, _from, state) do
    state = %{cancel_timer(state) | held: true, connect_token: nil}
    {:reply, :ok, state}
  end

  def handle_call({:reconnect, url}, _from, state) do
    # Down before the dial is queued, and the owner is not told. Matches the
    # Mint client closing its socket inside this call.
    state = %{cancel_timer(state) | held: false, url: url, up: false}

    state =
      case state.close_next do
        nil ->
          request_connect(state, 0)

        {code, reason} ->
          state = send_preface(%{state | up: true, close_next: nil})
          peer_closed(state, code, reason)
      end

    {:reply, :ok, state}
  end

  def handle_call({:preface, message}, _from, state) do
    {:reply, :ok, %{state | preface: message}}
  end

  def handle_call({:deliver, message}, _from, %{up: true} = state) do
    send(state.owner, {:from_plane, message})
    {:reply, :ok, state}
  end

  def handle_call({:deliver, _message}, _from, state), do: {:reply, :closed, state}

  def handle_call({:disconnect, code, reason}, _from, state) do
    {:reply, :ok, peer_closed(state, code, reason)}
  end

  def handle_call(:sent, _from, state), do: {:reply, Enum.reverse(state.sent), state}

  def handle_call(:allow, _from, state), do: {:reply, :ok, %{state | accept: true}}

  def handle_call({:close_next, code, reason}, _from, state) do
    {:reply, :ok, %{state | close_next: {code, reason}}}
  end

  @impl true
  def handle_info({:connect, token}, %{connect_token: token, held: false} = state) do
    connect(%{state | timer: nil, connect_token: nil})
  end

  def handle_info({:connect, _token}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp connect(%{accept: false} = state), do: schedule(%{state | up: false})

  defp connect(state) do
    state = send_preface(%{state | up: true})
    {:noreply, flush(state)}
  end

  defp send_preface(%{preface: message} = state) when is_map(message) do
    %{state | sent: [message | state.sent]}
  end

  defp send_preface(state), do: state

  defp transmit(message, %{up: true} = state), do: %{state | sent: [message | state.sent]}
  defp transmit(message, state), do: enqueue(state, message)

  defp enqueue(state, message), do: %{state | outbox: [message | state.outbox]}

  defp flush(%{outbox: []} = state), do: state

  defp flush(state) do
    flush_pending(Enum.reverse(state.outbox), %{state | outbox: []})
  end

  defp flush_pending([], state), do: state

  defp flush_pending([message | rest], state) do
    state = transmit(message, state)

    if up?(state) do
      flush_pending(rest, state)
    else
      %{state | outbox: Enum.reverse(rest) ++ state.outbox}
    end
  end

  defp peer_closed(%{up: false} = state, _code, _reason), do: state

  defp peer_closed(state, code, reason) do
    send(state.owner, {:transport_closed, code, reason})
    state = %{state | up: false}

    if state.held do
      %{cancel_timer(state) | connect_token: nil}
    else
      request_connect(state, state.backoff)
    end
  end

  defp schedule(%{held: true} = state) do
    {:noreply, %{cancel_timer(state) | connect_token: nil}}
  end

  defp schedule(state), do: {:noreply, request_connect(state, state.backoff)}

  defp request_connect(state, delay) when delay <= 0 do
    state = cancel_timer(state)
    token = make_ref()
    send(self(), {:connect, token})
    %{state | timer: nil, connect_token: token}
  end

  defp request_connect(state, delay) do
    state = cancel_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:connect, token}, delay)
    %{state | timer: timer, connect_token: token}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp retry_delay(delay) when is_integer(delay) and delay >= @min_backoff, do: delay
  defp retry_delay(_delay), do: @min_backoff

  defp up?(%{up: up}), do: up
end
