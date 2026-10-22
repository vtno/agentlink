# Names

`owner` is the pid that receives inbound ACP. It is not a supervisor. Do not call that field `parent`.

A module that belongs to one side is prefixed `Client` or `Agent`. The app connection is `Pont.ClientSocket`. The sidecar connection is `Pont.AgentSocket`. `Pont.Client` is one app on the plane. `Pont.AgentSlot` is one agent on the plane.
