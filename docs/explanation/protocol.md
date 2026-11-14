# Protocol paths

The plane exposes two WebSocket paths because the two peers are not the same kind of program. `/agent` is the uplink. `/acp` is a client. Both require the token. `GET /health` does not, so a monitor can check the listener without the secret.

## Why the uplink says hello

A client sends ACP immediately. An uplink must say which relay it is before any ACP frame, because the plane allows one live socket per link name. The first frame is a JSON-RPC request whose method is `agentlink.uplink`. The params carry the name, the label, the program, and an instance id.

The instance id is how the plane tells "this relay dialed again" from "a different relay wants the same name". A new uplink process in the same VM keeps the id. A second operating system process gets a new id. Replacing the previous socket, and dropping that name's session state, is the right outcome for a relay that lost its connection and came back. Rejecting the other process is the right outcome while the first one is still connected. The close codes and the JSON-RPC errors are in [Client and uplink protocol](../reference/protocol.md).

## Why some session methods stop at the plane

`session/list`, `session/load`, `session/resume`, and `session/close` are answered from the plane's session directory. They are not forwarded to the agent. A client that reconnects can list sessions and replay stored updates without asking the agent to become a database. `session/load` sends the replay and then an empty result. `session/resume` joins the session and does not replay. `session/close` drops that client's subscription and leaves the stored session in place.

`session/new` is forwarded. On success the plane opens a directory entry. Live `session/update` notifications are stored and sent to each client that has the session open.

The directory is capped. It keeps the newest whole turns that fit 50 turns and 1,000,000 bytes. The newest turn stays even when that turn alone is larger than the byte cap. A cut replay starts with an `agent_message_chunk` whose text is `Earlier turns were omitted.`

## Why initialize is cached

The agent should see one `initialize`. Later clients on that runtime receive the cached result, and each client still keeps the `clientCapabilities` from its own request. The agent therefore does not change personality every time an editor connects. The cost is that the agent never sees a later client's capabilities. File and terminal requests are checked against the client that owns the in-flight prompt, using that client's own capabilities, not the cached agent result.

The plane runs one `session/prompt` at a time per agent. A second prompt waits. An agent question goes to the client that has the matching prompt in flight, because that is the client that can answer it. If none match, or more than one match, the plane tells the agent that no app is attached.

## What the client relay rewrites

`agentlink connect` copies ACP unchanged after it has selected a runtime, with one exception. An `initialize` result advertises `loadSession` and session capabilities for `list`, `resume`, and `close`. The plane implements those methods, so the editor has to be told they exist even when the agent did not advertise them. A capability value that is already a map is left as it is.

For `session/new` and `session/load`, the relay fills a missing, null, or empty `cwd` with the relay workspace before the agent sees the message. Any other `cwd` is left unchanged. That path is on the agent's machine. The plane's directory, if it has to store a cwd before that fill, uses the workspace on the plane's machine. Set `cwd` in the request when the two machines should record the same path.
