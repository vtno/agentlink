# Glossary

Plane. Accepts sockets and applies the access policy.

Socket. One WebSocket on the plane. `Pont.ClientSocket` is the app. `Pont.AgentSocket` is the agent connection. The uplink dials `Pont.AgentSocket`.

Relay. Copies JSON-RPC between a local stdio and a plane socket. `Pont.Relay.Agent` opens an agent and starts an uplink. `Pont.Relay.Client` is not built yet.

Link. The file the agent relay reads before the uplink dials. Name, label, program, and plane URL. Not the live connection.

Uplink. `Pont.Uplink` is the process that dials. `Pont.Registry.Uplink` is the row recorded after that dial says hello.

Agent. The stdio behaviour. `Pont.OpenCode` implements it and runs the binary. The relay opens the behaviour. The relay does not spawn the binary.

Client. One app already connected to the plane. Not `Pont.Relay.Client`, and not `Pont.ClientSocket`.

Slot. The plane's session state for one connected agent. Prompt queue, the in-flight turn, and the cached `initialize`.
