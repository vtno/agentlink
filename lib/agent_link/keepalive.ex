defmodule AgentLink.Keepalive do
  @moduledoc """
  Ping interval and pong deadline for a WebSocket.

  `AgentLink.Transport.WebSocket` reads the durations through `milliseconds/6`.
  `AgentLink.AgentSocket` and `AgentLink.ClientSocket` also arm the timers
  here. The first accepted source wins. A start option, then
  `AGENTLINK_WEBSOCKET_PING_INTERVAL` or `AGENTLINK_WEBSOCKET_PONG_TIMEOUT`,
  then `:websocket_ping_interval` or `:websocket_pong_timeout`, then 30000
  and 10000. A source counts only when it is a positive integer up to
  4294967295. A blank value is skipped. Any other value is logged and skipped.

  The first ping waits one interval. Each later ping is one interval after
  the tick that sent the previous ping. The payload is empty. A pong clears
  the deadline. A deadline that is already armed stays where it is. If no
  pong arrives within the pong timeout, the socket stops. The close code is
  1001 and the reason is `keepalive pong timeout`.
  """

  require Logger

  @default_interval 30_000
  @default_timeout 10_000

  # `Process.send_after/3` rejects a larger timeout.
  @max_timer 4_294_967_295

  @close {1001, "keepalive pong timeout"}

  defstruct [
    :interval,
    :timeout,
    :scheduler,
    ping_timer: nil,
    ping_token: nil,
    pong_timer: nil,
    pong_token: nil
  ]

  @type t :: %__MODULE__{
          interval: pos_integer(),
          timeout: pos_integer(),
          scheduler: module(),
          ping_timer: reference() | nil,
          ping_token: reference() | nil,
          pong_timer: reference() | nil,
          pong_token: reference() | nil
        }

  @type info_result ::
          {:push, [{:ping, <<>>}], t()}
          | {:stop, {:shutdown, :keepalive_pong_timeout}, {1001, binary()}, t()}
          | :ignore

  @doc """
  One duration in milliseconds.

  `opt_key` is read from `opts` first. Then the environment variable
  `env_name`. Then the `:agent_link` application key `app_key`. Then
  `default`. `prefix` is the start of the warning for a skipped value.
  The dial uses `transport keepalive`. A plane socket uses `plane keepalive`.
  """
  @spec milliseconds(keyword(), atom(), atom(), String.t(), pos_integer(), String.t()) ::
          pos_integer()
  def milliseconds(opts, opt_key, app_key, env_name, default, prefix \\ "transport keepalive")
      when is_list(opts) and is_atom(opt_key) and is_atom(app_key) and is_binary(env_name) and
             is_integer(default) and default > 0 and is_binary(prefix) do
    sources = [
      {opt_key, Keyword.get(opts, opt_key, :unset)},
      {env_name, env_setting(env_name)},
      {app_key, Application.get_env(:agent_link, app_key, :unset)}
    ]

    case first_ms(sources, prefix) do
      {:ok, milliseconds} -> milliseconds
      :unset -> default
    end
  end

  @doc """
  Durations for one socket. The first ping is not armed yet.

  `:scheduler` defaults to `Process`. It implements `send_after/3` and
  `cancel_timer/1`. The cancellation return value is ignored. `:ping_interval`
  and `:pong_timeout` are milliseconds. See the module doc for the order of
  options, environment variables, and application env.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      interval:
        milliseconds(
          opts,
          :ping_interval,
          :websocket_ping_interval,
          "AGENTLINK_WEBSOCKET_PING_INTERVAL",
          @default_interval,
          "plane keepalive"
        ),
      timeout:
        milliseconds(
          opts,
          :pong_timeout,
          :websocket_pong_timeout,
          "AGENTLINK_WEBSOCKET_PONG_TIMEOUT",
          @default_timeout,
          "plane keepalive"
        ),
      scheduler: Keyword.get(opts, :scheduler, Process)
    }
  end

  @doc "Arm the first ping. The wait is one interval."
  @spec arm(t(), pid()) :: t()
  def arm(%__MODULE__{} = keepalive, pid) when is_pid(pid) do
    schedule_ping(keepalive, pid)
  end

  @doc """
  A timer message for this socket.

  `{:keepalive_ping, token}` is the open ping. The result asks the socket to
  send an empty ping. `{:keepalive_expired, token}` is the open pong deadline.
  The result stops the socket. Any other message, including a token that is
  no longer current, is `:ignore`.
  """
  @spec handle_info(term(), t(), pid()) :: info_result()
  def handle_info({:keepalive_ping, token}, %__MODULE__{ping_token: token} = keepalive, pid)
      when not is_nil(token) and is_pid(pid) do
    keepalive = %{keepalive | ping_timer: nil, ping_token: nil}
    keepalive = keepalive |> arm_pong(pid) |> schedule_ping(pid)
    {:push, [{:ping, ""}], keepalive}
  end

  def handle_info({:keepalive_ping, _token}, %__MODULE__{}, _pid), do: :ignore

  # `{:shutdown, _}` exits the socket process at once, so a registry monitor
  # runs now. `:normal` would leave the process up until the peer finished
  # the close handshake. OTP does not log a shutdown tuple.
  def handle_info({:keepalive_expired, token}, %__MODULE__{pong_token: token} = keepalive, _pid)
      when not is_nil(token) do
    Logger.warning("plane keepalive expired")
    {:stop, {:shutdown, :keepalive_pong_timeout}, @close, cancel_all(keepalive)}
  end

  def handle_info({:keepalive_expired, _token}, %__MODULE__{}, _pid), do: :ignore

  def handle_info(_message, %__MODULE__{}, _pid), do: :ignore

  @doc """
  A control frame for this socket.

  A pong clears the deadline. A ping does not. The server has already sent
  the pong for that ping.
  """
  @spec handle_control({binary(), keyword()} | term(), t()) :: {:ok, t()}
  def handle_control({_payload, [opcode: :pong]}, %__MODULE__{} = keepalive) do
    cancel(keepalive, keepalive.pong_timer)
    {:ok, %{keepalive | pong_timer: nil, pong_token: nil}}
  end

  def handle_control(_frame, %__MODULE__{} = keepalive), do: {:ok, keepalive}

  # A shorter interval must not postpone a pong that is already late.
  defp arm_pong(%__MODULE__{pong_token: token} = keepalive, _pid) when not is_nil(token) do
    keepalive
  end

  defp arm_pong(%__MODULE__{} = keepalive, pid) do
    token = make_ref()
    timer = keepalive.scheduler.send_after(pid, {:keepalive_expired, token}, keepalive.timeout)
    %{keepalive | pong_timer: timer, pong_token: token}
  end

  defp schedule_ping(%__MODULE__{} = keepalive, pid) do
    cancel(keepalive, keepalive.ping_timer)
    token = make_ref()
    timer = keepalive.scheduler.send_after(pid, {:keepalive_ping, token}, keepalive.interval)
    %{keepalive | ping_timer: timer, ping_token: token}
  end

  defp cancel_all(%__MODULE__{} = keepalive) do
    cancel(keepalive, keepalive.ping_timer)
    cancel(keepalive, keepalive.pong_timer)
    %{keepalive | ping_timer: nil, ping_token: nil, pong_timer: nil, pong_token: nil}
  end

  defp cancel(_keepalive, nil), do: :ok
  defp cancel(%__MODULE__{} = keepalive, timer), do: keepalive.scheduler.cancel_timer(timer)

  defp env_setting(name) do
    case System.get_env(name) do
      nil -> :unset
      value -> blank_as_unset(String.trim(value))
    end
  end

  defp blank_as_unset(""), do: :unset
  defp blank_as_unset(value), do: value

  defp first_ms([], _prefix), do: :unset

  defp first_ms([{_name, value} | rest], prefix) when value in [:unset, nil],
    do: first_ms(rest, prefix)

  defp first_ms([{name, value} | rest], prefix) do
    case parse_ms(value) do
      {:ok, milliseconds} ->
        {:ok, milliseconds}

      :error ->
        Logger.warning("#{prefix} #{name} ignored #{inspect(shown(value))}")
        first_ms(rest, prefix)
    end
  end

  defp parse_ms(value) when is_integer(value) and value > 0 and value <= @max_timer do
    {:ok, value}
  end

  defp parse_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} -> parse_ms(milliseconds)
      _other -> :error
    end
  end

  defp parse_ms(_value), do: :error

  defp shown(value) when is_binary(value) and byte_size(value) > 64 do
    binary_part(value, 0, 64) <> "..."
  end

  defp shown(value), do: value
end
