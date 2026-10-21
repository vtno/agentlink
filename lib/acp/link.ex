defmodule Acp.Link do
  @moduledoc """
  The sidecar's link configuration. The name in this file is what the uplink
  sends when it dials the plane. `ACP_RUNTIME_NAME` and `ACP_PLANE_URL` still
  override it for a machine that injects them from the environment.
  """

  @path "/workspace/bridge/agent.link.json"

  defstruct name: "opencode", label: "this machine", plane_url: "ws://127.0.0.1:8090/agent"

  @doc "Where the link file lives."
  def path, do: @path

  @doc "The link this machine dials with. Environment variables override the file."
  def read(path \\ @path) do
    raw = read_json(path)
    label = present(raw["label"]) || present(raw["name"]) || "this machine"
    name = slug(System.get_env("ACP_RUNTIME_NAME") || raw["name"] || label)
    name = if name == "", do: "opencode", else: name

    %__MODULE__{
      name: name,
      label: label,
      plane_url: System.get_env("ACP_PLANE_URL") || raw["plane_url"] || "ws://127.0.0.1:8090/agent"
    }
  end

  def slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end

  def slug(_), do: ""

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_), do: nil
end
