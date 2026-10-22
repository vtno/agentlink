# Harness

Sidecar does not spawn OpenCode itself. It opens the agent through `Pont.Harness`. Production is `Pont.OpenCode`. Tests set `:pont, :harness` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.
