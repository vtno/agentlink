# Names

`owner` is the pid that receives inbound ACP. It is not a supervisor. Do not call that field `parent`.

A module that belongs to one side is prefixed `Client` or `Agent`. The app connection is `AgentLink.ClientSocket`. The agent connection is `AgentLink.AgentSocket`. `AgentLink.Relay.Agent` starts the uplink and opens an `AgentLink.Agent`. `AgentLink.Uplink` dials that socket. `AgentLink.Client` is one app on the plane. `AgentLink.AgentSlot` is the slot for one connected agent. `AgentLink.Agent.Launch` is the raw command and args from the link file. It is not a process. `AgentLink.Agent.Process` opens an `AgentLink.Agent.Launch` from the caller. It is not a GenServer. The relay calls `open/3`. The handle is the port. `open/4` takes a finder and is not the behaviour callback. `AgentLink.Agent.Reaper` keeps the pid and start time of an agent `close/1` could not stop. It starts before `AgentLink.Relay.Agent`. The next relay asks it to signal those processes before `open/3`.
