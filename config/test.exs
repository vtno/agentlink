import Config

config :pont,
  harness: Pont.FakeHarness,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/pont-test-workdir"

config :logger, level: :warning
