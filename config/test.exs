import Config

config :agent_link,
  agent_module: AgentLink.FakeAgent,
  mode: :plane,
  port: 18_090,
  workdir: "/tmp/agentlink-test-workdir",
  cli: false

config :logger, level: :warning
