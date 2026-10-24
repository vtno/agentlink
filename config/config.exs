import Config

config :pont,
  port: 8090,
  mode: :all,
  plane_url: "ws://127.0.0.1:8090/agent",
  master_token: nil,
  agent_module: Pont.OpenCode,
  access: Pont.Access.Single,
  cli: true

config :logger, level: :info

if config_env() == :test do
  import_config "test.exs"
end
