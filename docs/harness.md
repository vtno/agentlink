# Harness

Sidecar does not spawn OpenCode itself. It opens the agent through `Acp.Harness`. Production is `Acp.OpenCode`. Tests set `:acp, :harness` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.
