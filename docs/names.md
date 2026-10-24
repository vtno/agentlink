# Names

`owner` is the pid that receives inbound ACP. It is not a supervisor. Do not call that field `parent`.

A module that belongs to one side is prefixed `Client` or `Agent`. The app connection is `Pont.ClientSocket`. The agent connection is `Pont.AgentSocket`. `Pont.Relay.Agent` starts the uplink and opens a `Pont.Agent`. `Pont.Uplink` dials that socket. `Pont.Client` is one app on the plane. `Pont.AgentSlot` is the slot for one connected agent.
