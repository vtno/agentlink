defmodule AgentLink.Relay.Target do
  @moduledoc """
  Selects the target agent from the names that are online. The caller
  supplies those names. This module starts no process and defines no
  Elixir behaviour. `AgentLink.Relay.Client` calls `select/2`.
  """

  @doc """
  Pick the agent named by `wanted`, or the only online agent when `wanted` is nil.

  `wanted` is the requested name, or nil. `online` is the names the caller
  says are online. A repeated name counts once, and the first occurrence
  keeps its place. An empty string is a name. `select/2` keeps the bytes as
  given, so `"Alice"` and `"alice"` are different names.

  When `wanted` occurs in `online`, the result is `{:ok, wanted}`. When
  `wanted` is nil and one name remains, the result is `{:ok, name}`. When
  no name remains, the error says that no agent is online, including when
  `wanted` is set. When `wanted` is nil and more than one name remains, the
  error lists those names and tells the operator to pass `--target`. When
  `wanted` is not one of the online names, the error names `wanted`, lists
  the online names, and tells the operator to pass `--target`. Each name in
  an error is `inspect/1` of that binary.

  A `wanted` that is not a binary or nil raises `ArgumentError`. An `online`
  that is not a list, or an entry that is not a binary, raises `ArgumentError`.
  """
  @spec select(wanted :: String.t() | nil, online :: [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def select(wanted, online) when is_binary(wanted) or is_nil(wanted) do
    choose(wanted, names!(online))
  end

  def select(wanted, _online) do
    raise ArgumentError, "wanted must be a binary or nil, got: #{inspect(wanted)}"
  end

  defp choose(_wanted, []), do: {:error, "No agent is online.\n"}

  defp choose(wanted, names) when is_binary(wanted) do
    if wanted in names do
      {:ok, wanted}
    else
      {:error,
       "#{inspect(wanted)} is not online. Online agents: #{show(names)}. Pass --target.\n"}
    end
  end

  defp choose(nil, [name]), do: {:ok, name}

  defp choose(nil, names) do
    {:error, "Several agents are online: #{show(names)}. Pass --target NAME.\n"}
  end

  defp names!(online) when is_list(online) do
    online
    |> Enum.map(fn
      name when is_binary(name) -> name
      other -> raise ArgumentError, "online names must be binaries, got: #{inspect(other)}"
    end)
    |> Enum.uniq()
  end

  defp names!(other) do
    raise ArgumentError, "online must be a list of binaries, got: #{inspect(other)}"
  end

  defp show(names), do: Enum.map_join(names, ", ", &inspect/1)
end
