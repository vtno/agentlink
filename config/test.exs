import Config

config :pont,
  agent_module: Pont.FakeAgent,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/pont-test-workdir"

config :logger, level: :warning
