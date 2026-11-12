import Config

config :agent_link,
  agent_module: AgentLink.FakeAgent,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/agentlink-test-workdir",
  reaper_dir: "/tmp/agentlink-test-reaper",
  config_root: Path.join(System.tmp_dir!(), "agentlink-test-config-#{System.pid()}"),
  config_env: %{},
  cli: false

config :logger, level: :warning
