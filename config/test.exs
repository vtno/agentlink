import Config

config :acp,
  harness: Acp.FakeHarness,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/acp-test-workdir"

config :logger, level: :warning
