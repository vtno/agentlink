defmodule Pont.Access do
  @moduledoc """
  Who a connection is, and which uplink that subject may use.
  The plane calls this module. The configured implementation does the work.
  """

  defmodule Subject do
    @moduledoc "The identity attached to one connection. An empty struct is not an admin."
    defstruct [:id, :role]
  end

  @doc "Resolve the caller. `:reject` closes the connection."
  @callback authenticate(Plug.Conn.t()) :: {:ok, Subject.t()} | :reject

  @doc "True when this subject may use this uplink."
  @callback allowed?(Subject.t(), name :: String.t()) :: boolean

  @doc "An uplink is claiming its name. `:reject` refuses the hello. A policy may omit this."
  @callback claim(Subject.t(), name :: String.t()) :: :ok | :reject

  @doc "Install this policy before the sockets open. Return text for the operator, or an error."
  @callback prepare(mode :: atom()) :: {:ok, String.t()} | {:error, String.t()}

  @optional_callbacks [claim: 2]

  @doc "The implementation named by `:access`. `Pont.Access.Single` when unset."
  def implementation do
    module = Application.get_env(:pont, :access, Pont.Access.Single)

    cond do
      not Code.ensure_loaded?(module) ->
        raise ArgumentError, "access module #{inspect(module)} is not loaded"

      not function_exported?(module, :authenticate, 1) or
        not function_exported?(module, :allowed?, 2) or
          not function_exported?(module, :prepare, 1) ->
        raise ArgumentError, "access module #{inspect(module)} does not implement Pont.Access"

      true ->
        module
    end
  end

  @doc "Resolve the caller through the configured implementation."
  def authenticate(conn), do: implementation().authenticate(conn)

  @doc "Name the caller of the agent socket. The request must present the master token."
  def agent_caller(conn) do
    cond do
      not Pont.Auth.enabled?() ->
        {:reject, "No token is set."}

      not Pont.Auth.allowed?(conn) ->
        {:reject, "The master token did not match."}

      true ->
        case authenticate(conn) do
          {:ok, %Subject{} = subject} -> {:ok, subject}
          :reject -> {:reject, "The access policy rejected it."}
        end
    end
  end

  @doc "Ask the configured implementation if this subject may use this uplink."
  def allowed?(subject, name) when is_binary(name) do
    implementation().allowed?(subject, name)
  end

  @doc "Ask the configured policy to accept this uplink. A policy without claim/2 accepts it."
  def claim(%Pont.Access.Subject{} = subject, name) when is_binary(name) do
    module = implementation()

    if function_exported?(module, :claim, 2) do
      case module.claim(subject, name) do
        :ok -> :ok
        :reject -> {:error, "uplink is not allowed"}
      end
    else
      :ok
    end
  end

  @doc "Let the configured policy install credentials and describe how to connect."
  def prepare do
    implementation().prepare(Application.fetch_env!(:pont, :mode))
  end
end
