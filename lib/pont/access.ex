defmodule Pont.Access do
  @moduledoc """
  Who a connection is, and which uplink that subject may use.
  The plane calls this module. The configured implementation does the work.
  """

  defmodule Subject do
    @moduledoc "The identity attached to one app connection."
    defstruct id: "admin", role: :admin
  end

  @doc "Resolve the caller. `:reject` closes the connection."
  @callback authenticate(Plug.Conn.t()) :: {:ok, Subject.t()} | :reject

  @doc "True when this subject may use this uplink."
  @callback allowed?(Subject.t(), name :: String.t()) :: boolean

  @doc "A sidecar is claiming this uplink. `:reject` refuses the dial."
  @callback claim(Subject.t(), name :: String.t()) :: :ok | :reject

  @doc "Install this policy before the sockets open. Return text for the operator, or an error."
  @callback prepare(mode :: atom()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "The implementation named by `:access`. `Pont.Access.Single` when unset."
  def implementation do
    module = Application.get_env(:pont, :access, Pont.Access.Single)

    cond do
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, "access module #{inspect(module)} is not loaded"

      not function_exported?(module, :authenticate, 1) or
          not function_exported?(module, :allowed?, 2) or
          not function_exported?(module, :claim, 2) or
          not function_exported?(module, :prepare, 1) ->
        raise ArgumentError, "access module #{inspect(module)} does not implement Pont.Access"

      true ->
        module
    end
  end

  @doc "Resolve the caller through the configured implementation."
  def authenticate(conn), do: implementation().authenticate(conn)

  @doc "Ask the configured implementation if this subject may use this uplink."
  def allowed?(subject, name) when is_binary(name) do
    implementation().allowed?(subject, name)
  end

  @doc "Ask the configured policy to accept this uplink. `:reject` becomes an error."
  def claim(subject, name) when is_binary(name) do
    case implementation().claim(subject, name) do
      :ok -> :ok
      :reject -> {:error, "uplink is not allowed"}
    end
  end

  @doc "Let the configured policy install credentials and describe how to connect."
  def prepare do
    implementation().prepare(Application.fetch_env!(:pont, :mode))
  end
end
