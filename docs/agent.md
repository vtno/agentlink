# Agent

`Pont.Relay.Agent` does not spawn OpenCode itself. It opens the agent through `Pont.Agent`. Production is `Pont.OpenCode`. Tests set `:pont, :agent_module` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.

`Pont.Agent` is that behaviour. A link's `program` is only the product name, such as `opencode`. The name does not choose the module.
