import Config

mode =
  case System.get_env("ACP_MODE", "all") do
    "plane" -> :plane
    "agent" -> :agent
    _ -> :all
  end

config :acp,
  opencode_bin: System.get_env("OPENCODE_BIN") || "/workspace/node_modules/.bin/opencode",
  workdir: System.get_env("ACP_WORKDIR") || "/workspace/agent-workdir",
  port: String.to_integer(System.get_env("ACP_PORT") || "8090"),
  mode: mode,
  plane_url: System.get_env("ACP_PLANE_URL") || "ws://127.0.0.1:8090/agent",
  runtime_name: System.get_env("ACP_RUNTIME_NAME") || "opencode",
  runtime_label: System.get_env("ACP_RUNTIME_LABEL") || "this machine",
  harness: Acp.OpenCode

config :logger, level: :info
