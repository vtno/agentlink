# Glossary

Plane. Accepts sockets and applies the access policy.

Socket. One WebSocket on the plane. `Pont.ClientSocket` is the app connection. `Pont.AgentSocket` is the agent connection. The uplink dials `Pont.AgentSocket`.

Relay. Copies JSON-RPC between a local stdio and a plane socket. `Pont.Relay.Agent` opens an agent and starts an uplink. `Pont.Relay.Client` is not built yet.

Link. The file. Name, label, program, and plane URL. Not the live connection. The uplink reads it when it dials. A missing file stops the relay.

Uplink. `Pont.Uplink` is the process that dials. `Pont.Registry.Uplink` is the row recorded after that dial says hello. The first live hello for a name keeps the socket. The hello carries that relay's instance id, and "same relay" means the same id: a later hello with it releases the previous socket. A hello from another relay is rejected with close code 4001, and that relay parks until the `name` or `plane_url` in the link file changes, then it dials again. When the holder disconnects, the name is free. The plane accepts an instance id of at most 128 bytes. A longer id is rejected with close code 4002, and that relay does not redial: the id is not in the link file, so a changed `name` or `plane_url` would dial with the same id.

Agent. The stdio behaviour. `Pont.OpenCode` implements it and runs the binary. The relay opens the behaviour. The relay does not spawn the binary.

Client. One app already connected to the plane. Not `Pont.Relay.Client`, and not `Pont.ClientSocket`. Its capabilities are the `clientCapabilities` from that app's own `initialize`.

Slot. The plane's session state for one connected agent. Prompt queue, the in-flight turn, and the cached `initialize`. The cache is the agent's reply, not the client's capabilities.
