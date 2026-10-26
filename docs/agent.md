# Agent

`Pont.Relay.Agent` does not spawn OpenCode itself. It opens the agent through `Pont.Agent`. `Pont.OpenCode` is the production behaviour and runs the binary. Tests set `:pont, :agent_module` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.

`Pont.Agent` is that behaviour. A link's `program` is only the product name, such as `opencode`. The name does not choose the module.

For `session/new` and `session/load`, the relay fills a missing, null, or empty `cwd` in params with its workspace, `Pont.Paths.workdir()`, before the message reaches the agent. An explicit `cwd` passes through unchanged.
