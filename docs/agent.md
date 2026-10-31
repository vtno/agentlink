# Agent

`AgentLink.Relay.Agent` does not spawn OpenCode itself. It opens the agent through `AgentLink.Agent`. `AgentLink.OpenCode` is the production behaviour and runs the binary. Tests set `:agent_link, :agent_module` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.

`AgentLink.Agent` is that behaviour. A link's `program` is only the product name, such as `opencode`. The name does not choose the module.

For `session/new` and `session/load`, the relay fills a missing, null, or empty `cwd` in params with its workspace, `AgentLink.Paths.workdir()`, before the message reaches the agent. An explicit `cwd` passes through unchanged.
