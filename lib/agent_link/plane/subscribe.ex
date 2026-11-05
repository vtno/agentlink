defmodule AgentLink.Plane.Subscribe do
  @moduledoc """
  One subscription for a session a client has open. The session holds the
  subscription pid. It does not store the client id.

  `AgentLink.Plane.Subscribe` is the behaviour. `AgentLink.Plane.Subscription`
  is the production implementation. Tests use `AgentLink.FakeSubscribe`.

  `start_link/1` requires `:client_pid`, `:client_id`, `:session_id`, and
  `:owner`. None of them has a default. `:client_pid` and `:owner` are pids.
  `:client_id` and `:session_id` are binaries.

  When `:client_pid` dies, `:owner` receives
  `{:subscription_down, client_id, session_id}` and the process exits with
  `:normal`. `start_link/1` links to the caller, and `:normal` leaves that
  caller running. `stop/1` also exits with `:normal`. `:owner` receives no message
  from `stop/1`. The session directory starts one when a client opens, loads,
  or resumes a session.
  """

  @doc """
  Start the subscription.

  `:client_pid` and `:owner` are pids. `:client_id` and `:session_id` are
  binaries. All four are required.
  """
  @callback start_link(keyword) :: GenServer.on_start()

  @doc "Pass one ACP object to this subscription."
  @callback notify(server :: term, message :: map) :: :ok

  @doc """
  End this subscription.

  The process exits with `:normal`. Returns `:ok`, including when the process
  has already stopped.
  """
  @callback stop(server :: term) :: :ok
end
