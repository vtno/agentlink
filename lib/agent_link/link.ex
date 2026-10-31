defmodule AgentLink.Link do
  @moduledoc """
  The relay's link file. The uplink sends this name when it dials.
  A missing file stops the relay. The file holds the name, the label, the program, and the plane URL.
  """

  defstruct name: "opencode",
            label: "this machine",
            program: "opencode",
            plane_url: "ws://127.0.0.1:8090/agent"

  @doc "Where the link file lives."
  def path, do: AgentLink.Paths.link()

  @doc "Read the link file. An error tells the operator to create it."
  def read(path \\ nil) do
    path = path || path()

    case File.read(path) do
      {:ok, body} -> decode(path, body)
      {:error, :enoent} -> {:error, missing(path)}
      {:error, reason} -> {:error, "Could not read #{path}: #{inspect(reason)}\n"}
    end
  end

  @doc """
  The slug a link name becomes. Lowercase, with runs of non-alphanumerics
  collapsed to single dashes, the outer dashes trimmed, and the result cut
  to `AgentLink.Registry.max_name_chars()` characters. The plane rejects a
  longer name, so a slug always passes.
  """
  def slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, AgentLink.Registry.max_name_chars())
  end

  def slug(_), do: ""

  defp decode(path, body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, from_map(map)}
      _ -> {:error, "#{path} is not a JSON object.\n"}
    end
  end

  defp from_map(raw) do
    label = present(raw["label"]) || present(raw["name"]) || "this machine"
    name = slug(present(raw["name"]) || label)
    name = if name == "", do: "opencode", else: name

    %__MODULE__{
      name: name,
      label: label,
      program: present(raw["program"]) || "opencode",
      plane_url: present(raw["plane_url"]) || AgentLink.Paths.plane_url()
    }
  end

  defp missing(path) do
    """
    No link file at #{path}.
    The agent relay stops until you create it. Example:

    {
      "name": "opencode",
      "label": "this machine",
      "program": "opencode",
      "plane_url": "#{AgentLink.Paths.plane_url()}"
    }
    """
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_), do: nil
end
