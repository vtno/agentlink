# Names

`owner` is the pid that receives inbound ACP. It is not a supervisor. Do not call that field `parent`.

A module that belongs to one side is prefixed `Client` or `Agent`. The app connection is `Acp.ClientSocket`. The sidecar connection is `Acp.AgentSocket`. `Acp.Client` is one app on the plane. `Acp.AgentSlot` is one agent on the plane.
