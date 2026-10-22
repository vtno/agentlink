import Config

mode =
  case System.get_env("PONT_MODE", "all") do
    "plane" -> :plane
    "agent" -> :agent
    _ -> :all
  end

config :pont,
  opencode_bin: System.get_env("OPENCODE_BIN"),
  workdir: System.get_env("PONT_WORKDIR"),
  port: String.to_integer(System.get_env("PONT_PORT") || "8090"),
  mode: mode,
  plane_url: System.get_env("PONT_PLANE_URL") || "ws://127.0.0.1:8090/agent",
  runtime_name: System.get_env("PONT_RUNTIME_NAME") || "opencode",
  runtime_label: System.get_env("PONT_RUNTIME_LABEL") || "this machine",
  harness: Pont.OpenCode

config :logger, level: :info

if config_env() == :test do
  import_config "test.exs"
end
