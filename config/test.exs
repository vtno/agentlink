import Config

config :pont,
  agent_module: Pont.FakeAgent,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/pont-test-workdir",
  cli: false

config :logger, level: :warning
