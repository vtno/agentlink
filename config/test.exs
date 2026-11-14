import Config

config :agent_link,
  agent_module: AgentLink.FakeAgent,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/agentlink-test-workdir",
  reaper_dir: "/tmp/agentlink-test-reaper",
  config_root: Path.join(System.tmp_dir!(), "agentlink-test-config-#{System.pid()}"),
  config_env: %{},
  cli: false,
  # Keep the real keepalive timer from firing during a test.
  # Tests that cover it pass `:ping_interval` or set the env themselves.
  websocket_ping_interval: 3_600_000,
  websocket_pong_timeout: 3_600_000

config :logger, level: :warning
