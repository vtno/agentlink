# Glossary

Plane. Accepts sockets and applies the access policy.

Socket. One WebSocket on the plane. `AgentLink.ClientSocket` is the app connection. `AgentLink.AgentSocket` is the agent connection. The uplink dials `AgentLink.AgentSocket`.

Relay. Copies JSON-RPC between a local stdio and a plane socket. `AgentLink.Relay.Agent` opens an agent and starts an uplink. `AgentLink.Relay.Client` is not built yet.

Frame. `AgentLink.Frame` is one JSON-RPC object on the wire. Stdio is one object per line. The agent relay and the uplink put one object in each text frame. On the plane, `AgentLink.Plane.client_frame/2` and `AgentLink.Plane.agent_frame/2` split that text on newlines, decode each piece, and keep no remainder. `client_frame/2` answers a JSON-RPC batch with -32600.

Transport. `AgentLink.Transport` is the WebSocket a relay dials. `AgentLink.Transport.WebSocket` is the Mint client. The owner receives `{:from_plane, message}` for one decoded object and `{:transport_closed, code, reason}` when that socket closes. `hold/1` stops the next dial. `preface/2` is the object sent before the outbox on every dial. `AgentLink.Uplink` dials through this behaviour.

Link. The file. Name, label, program, and plane URL. Not the live connection. The uplink reads it when it starts, on each watch, and on a non-parking close of the current socket. A missing file stops the relay.

Uplink. `AgentLink.Uplink` is the process that dials. `AgentLink.Registry.Uplink` is the row recorded after that dial says hello. The first live hello for a name keeps the socket. The hello carries that relay's instance id, and "same relay" means the same id: a later hello with it releases the previous socket. A hello from another relay is rejected with close code 4001, and that relay parks until the `name` or `plane_url` in the link file changes, then it dials again. When the holder disconnects, the name is free. The plane accepts an instance id of at most 128 bytes. A longer id is rejected with close code 4002, and that relay does not redial: the id is not in the link file, so a changed `name` or `plane_url` would dial with the same id.

Agent. The stdio behaviour. `AgentLink.OpenCode` implements it and runs the binary. The relay opens the behaviour. The relay does not spawn the binary.

Client. One app already connected to the plane. Not `AgentLink.Relay.Client`, and not `AgentLink.ClientSocket`. Its capabilities are the `clientCapabilities` from that app's own `initialize`.

Slot. The plane's session state for one connected agent. Prompt queue, the in-flight turn, and the cached `initialize`. The cache is the agent's reply, not the client's capabilities.

History. `AgentLink.Plane.History` is the replay buffer for one session. It keeps the newest whole turns that fit a turn limit and a byte limit. The newest turn stays even when that turn alone is larger than `:max_bytes`. A `user_message_chunk` starts a turn. Updates before the first one are one turn. The plane does not call it yet.

Subscription. `AgentLink.Plane.Subscription` is one process for a session a client has open. It implements `AgentLink.Plane.Subscribe`. `notify/2` sends `{:send, json}` to the client pid. `json` is `AgentLink.Frame.encode/1`. When the client dies, `:owner` receives `{:subscription_down, client_id, session_id}` and the process exits with `:normal`. `stop/1` also exits with `:normal`. The plane does not start these processes yet.

Session. `AgentLink.Plane.Session` is one shared session process. It holds an `AgentLink.Plane.History` and the subscription pids. `subscribe/2` returns the capped replay as full `session/update` messages, oldest first. `replay/1` returns that list and does not start a subscription. `broadcast/2` appends one inner update, then calls `notify/2` on each subscription. The session does not store client ids or client capabilities. The plane does not start it yet.

Sessions. `AgentLink.Plane.Sessions` is the directory of those sessions. `open/5` starts a session and subscribes the client. `load/4` subscribes and returns the replay, or `{:error, :unknown}`. `resume/4` subscribes and returns `:ok`, or `{:error, :unknown}`. `leave/3` drops one client from one session. `disconnect/1` drops that client from every session. Both remove the directory entry when the subscription has already exited. `list/2` filters on `:cwd` and pages with an opaque `:cursor`. The directory maps each client id to its subscription pids. The plane does not call the directory yet.

Agent socket protocol. `AgentLink.AgentSocketProtocol` defines the handshake's permanent-rejection close codes shared by the plane's agent socket and the relay's uplink: 4001 name taken, 4002 instance too long (maximum 128 bytes), 4003 bad name, 4004 not allowed. It does not cover the client socket. Each rejection parks the uplink with a logged reason. Restart retries any rejection; changing the link name or plane URL retries all except 4002. Other closes and transient failures retry after 500ms.
