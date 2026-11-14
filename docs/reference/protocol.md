# Client and uplink protocol

ACP messages are JSON-RPC objects. On an agent pipe, one object is one line. On a WebSocket, one object is one text frame. A text frame that is not JSON is JSON-RPC error `-32700` and the message `parse error`. A JSON-RPC batch on the client socket is error `-32600` and the message `JSON-RPC batches are not supported`.

## Uplink hello

The first object on every agent dial is a JSON-RPC request. The method is `agentlink.uplink`. The params are `name`, `label`, `program`, and `instance`.

`instance` identifies the operating system process. A new uplink process in the same VM keeps the same id. A second OS process has a new id. The plane accepts an id of at most 128 bytes. The id this VM generates is 16 random bytes encoded as unpadded base64url, which is 22 characters.

The first hello for a name keeps the socket. A later hello with the same instance releases the previous socket, keeps the new one, and drops that name's session state. In-flight requests fail with JSON-RPC error `-32000` and the message `runtime reconnected`.

A hello from a different relay, while the current relay is connected, is closed with code 4001. The existing row stays. When the holder disconnects, the name is free. In-flight requests then fail with JSON-RPC error `-32000` and the message `runtime disconnected`.

## Close codes

`AgentLink.AgentSocketProtocol` defines the permanent close codes. They apply to the agent socket and the uplink. They do not apply to the client socket. A parked uplink does not dial again on its own.

| Code | Reason | Next dial |
| --- | --- | --- |
| 4001 | `name "<name>" is in use; stop the other relay or change name` | After a change to `name` or `plane_url`, or after a restart |
| 4002 | `instance id is too long; max is 128 bytes` | After a restart. A change to `name` or `plane_url` does not dial. |
| 4003 | `link name must be a short slug` | After a change to `name` or `plane_url`, or after a restart |
| 4004 | `uplink is not allowed` | After a change to `name` or `plane_url`, or after a restart |

When `name` is not a string, code 4001 uses the reason `name is in use; stop the other relay or change name`.

A change to `label` or `program` does not dial again for code 4001, 4003, or 4004. Code 4004 means `AgentLink.Access` rejected the hello.

Any other close, and a failed dial, retries after 500 milliseconds.

Code 1006 is a local status, not a close code from the plane. The transport reports 1006 when the socket ends with no close frame. A missed pong is one case, and the reason text is then `keepalive pong timeout`. A socket error also uses 1006, and the reason is that error. Code 1006 does not park the uplink. [Reconnect and keepalive](../explanation/reconnect.md) describes the ping timer.

## Client socket

A client connects to `/acp` and sends the token as `Authorization: Bearer` or as `?token=`. The default URL is `ws://127.0.0.1:8090/acp`.

`runtime/list` returns an object whose `runtimes` array is the runtimes this caller may use. Each runtime has `name`, `label`, `program`, and `connected_at`.

`runtime/select` with `params.name` binds the client to that runtime. The result is that runtime's row. The errors are `runtime name is required`, `runtime is not connected`, and `runtime is not allowed`.

Other ACP methods need a selected runtime. When the caller may use exactly one connected runtime, the plane selects that runtime. Otherwise the error is one of these.

- `no runtime connected` when no runtime is connected.
- `runtime is not allowed` when runtimes are connected and this caller may use none of them.
- `select a runtime` when the caller may use several.

`agentlink connect` sends `runtime/list` with id `agentlink:runtime/list` and `runtime/select` with id `agentlink:runtime/select`. Those two responses are not written to the editor. Editor messages that arrive before `runtime/select` answers are copied after it, in order. A closed plane socket during either request sends that request again. After `runtime/select` succeeds, a closed plane socket stops the process with `plane closed`.

## Initialize

The plane forwards only the first `initialize` for a runtime. An `initialize` that arrives before the agent answers waits for that result. After the agent answers, a later `initialize` on that runtime receives the cached result. Each client keeps the `clientCapabilities` from its own `initialize`. The agent sees the capabilities from the first `initialize` only.

The client relay sets `agentCapabilities.loadSession` to true on an `initialize` result. `sessionCapabilities` gains the keys `list`, `resume`, and `close`. A value that is already a map stays. The agent's other capabilities stay. A result that is not a map is copied unchanged.

## Session methods

The plane forwards `session/new`. It answers `session/list`, `session/load`, `session/resume`, and `session/close` from the session directory and does not forward them.

`session/list` is paged. A page has at most 50 rows. Each row has `sessionId`, `cwd`, `title`, and `updatedAt`. A further page includes `nextCursor`. A cursor that does not decode is JSON-RPC error `-32602` and the message `invalid cursor`. A `cwd` filter that is not a string is `-32602` and the message `invalid cwd`.

For a known session, `session/load` sends the stored replay and then an empty result. An unknown session is JSON-RPC error `-32002` and the message `session not found`. `session/resume` joins a known session and does not replay. The same unknown-session error applies. `session/close` answers an empty result and drops that client from the session. The session stays in the directory, so a later `session/load` still replays. A second `session/close` for that session answers an empty result again. A load, resume, or close without a binary `sessionId` is `-32602` and the message `sessionId is required`.

The replay keeps the newest whole turns that fit 50 turns and 1,000,000 bytes. The newest turn stays even when it alone is larger than the byte cap. When the history was cut, the first replay update is an `agent_message_chunk` whose text is `Earlier turns were omitted.`

A client opens a session with `session/new`, `session/load`, or `session/resume`.

For `session/new` and `session/load`, the relay replaces a missing, null, or empty-string `cwd` with `$HOME/.agentlink/workspace` before the write to the agent. Any other `cwd` is unchanged. That path is on the agent's machine. The directory uses the plane machine's workspace when the request has no non-empty `cwd`.

## Prompt and agent requests

The agent runs one `session/prompt` at a time. Further prompts wait. An agent request goes to the client that has the matching `session/prompt` in flight. The plane applies the capability rules below to that client. When no client matches, or more than one client matches, the plane answers the agent with JSON-RPC error `-32000` and the message `no app is attached to this session`.

The plane forwards an agent file or terminal request only in these cases.

- `fs/read_text_file` when that client's `fs.readTextFile` is true.
- `fs/write_text_file` when that client's `fs.writeTextFile` is true.
- A method whose name starts with `terminal/` when that client's `terminal` is true.

Any other method whose name starts with `fs/` or `terminal/` is not forwarded. The refusal is JSON-RPC error `-32601` and the message `client does not support this method`.

A live `session/update` with a binary `sessionId` and a map `update` is sent to each client that has that session open. A `session/update` with a binary `sessionId` whose `update` is not a map is dropped. The plane logs a warning and does not store that update. A `session/update` with no `sessionId` is sent to every client on that runtime.
