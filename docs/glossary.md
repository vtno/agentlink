# Glossary

Plane. Accepts sockets and applies the access policy.

Socket. One WebSocket on the plane. `Pont.ClientSocket` is the app connection. `Pont.AgentSocket` is the agent connection. The uplink dials `Pont.AgentSocket`.

Relay. Copies JSON-RPC between a local stdio and a plane socket. `Pont.Relay.Agent` opens an agent and starts an uplink. `Pont.Relay.Client` is not built yet.

Link. The file. Name, label, program, and plane URL. Not the live connection. The uplink reads it when it dials. A missing file stops the relay.

Uplink. `Pont.Uplink` is the process that dials. `Pont.Registry.Uplink` is the row recorded after that dial says hello. The first live hello for a name keeps the socket. A later hello from that same relay releases the previous socket. A hello from another relay is rejected, and that relay does not redial. When the holder disconnects, the name is free. The hello carries that relay's instance id. The plane accepts at most 128 bytes. A longer id is rejected, and that relay does not redial.

Agent. The stdio behaviour. `Pont.OpenCode` implements it and runs the binary. The relay opens the behaviour. The relay does not spawn the binary.

Client. One app already connected to the plane. Not `Pont.Relay.Client`, and not `Pont.ClientSocket`. Its capabilities are the `clientCapabilities` from that app's own `initialize`.

Slot. The plane's session state for one connected agent. Prompt queue, the in-flight turn, and the cached `initialize`. The cache is the agent's reply, not the client's capabilities.

Socket protocol. `Pont.SocketProtocol` defines the shared handshake's permanent-rejection close codes: 4001 name taken, 4002 instance too long (maximum 128 bytes), 4003 bad name, 4004 not allowed. Each parks the uplink with a logged reason. Restart retries any rejection; changing the link name or plane URL retries all except 4002. Other closes and transient failures retry after 500ms.
