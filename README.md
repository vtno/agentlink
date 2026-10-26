# Pont

> Pont means bridge in French.

Pont proxies [Agent Client Protocol](https://agentclientprotocol.com) traffic between a client and one agent. The plane accepts the app connection. The agent relay opens the agent. The uplink dials the agent socket.

ACP is JSON-RPC. The agent writes JSONL on its standard output. Pont sends one JSON value in each WebSocket text frame.

## Binary

The build machine needs Elixir 1.17 or newer, [Zig 0.16.0](https://ziglang.org/download/0.16.0/), and `xz`. A Windows binary also needs `7z` or `7zz`. The machine that runs Pont does not need Elixir.

```sh
mix deps.get
MIX_ENV=prod mix release
```

That writes three binaries to `burrito_out/`:

| File | Machine |
|---|---|
| `pont_linux` | Linux x86_64 |
| `pont_macos` | macOS Apple Silicon |
| `pont_windows.exe` | Windows x86_64 |

`BURRITO_TARGET=linux` builds one of them. The names are `linux`, `macos`, and `windows`. Put the binary on `PATH` as `pont`.

```sh
pont
pont plane --port 8090
pont relay --token 'the-token'
```

## Run from source

You need Elixir 1.17. To run an agent, you also need the `opencode` binary.

```sh
mix deps.get
mix run --no-halt
```

That starts the plane and the agent relay. Arguments go after `--`.

```sh
mix run --no-halt -- --port 8090 --token 'the-token'
mix run --no-halt -- plane --port 8090
mix run --no-halt -- relay --token 'the-token' --opencode-bin /usr/local/bin/opencode
```

`plane` is the plane alone. `relay` starts the relay alone. The relay reads `$HOME/.pont/agent.link.json` for the name, the label, the program, and the plane URL. `--port` is the plane's port. `--token` is the single-player token. `--opencode-bin` is the OpenCode executable when it is not on `PATH`. A plane with no token mints one and prints `pont relay --token '…'`.

## Routes

The plane serves these paths on port 8090.

| Path | Response |
|---|---|
| `GET /health` | The body is `ok`. |
| `GET /status` | JSON with the `plane` (listen address) and `runtimes` keys. `runtimes` is filtered by the access policy. |
| `GET /acp` | WebSocket for an ACP client. |
| `GET /agent` | WebSocket the uplink dials. |

A client connects to `ws://127.0.0.1:8090/acp`. It sends ACP requests such as `session/new`, `session/load`, and `session/prompt`. The agent keeps the first client's `clientCapabilities`: only the first `initialize` reaches it, and later clients answer from the cached `initialize`. Each client keeps the advertisement from its own `initialize`, and each agent-to-client request is gated against the client that issued the session. Pont returns a permission question only to the client that started that turn, or to the client that is loading that session when the question arrives during a `session/load`. File and terminal requests go to that client only when its own `initialize` advertised them. Otherwise the agent is answered with JSON-RPC `-32601` and the message `client does not support this method`.

## Link file

`Pont.Link` reads `$HOME/.pont/agent.link.json`. The agent relay refuses to start until that file exists. The file is the name, the label, the program, and the plane URL.

```json
{
  "name": "opencode",
  "label": "this machine",
  "program": "opencode",
  "plane_url": "ws://127.0.0.1:8090/agent"
}
```

`name` is the agent id, and it is slugged: `Lab Box` becomes `lab-box`. One plane keeps a single uplink for each name.

- The first uplink to register a name keeps the socket.
- That same relay can dial again, including after a label or program change and after a dropped socket: the plane releases the previous socket and keeps the new one. A same-relay reconnect drops the plane's session state for the name, and in-flight work for that runtime fails with `runtime reconnected`.
- A hello from a different relay is rejected with WebSocket code 4001 and the reason `name "<name>" is in use; stop the other relay or change name`. That relay logs the clash and does not redial until `name` or `plane_url` in this file changes. When the holder disconnects, the name is free for a new dial.
- The hello also carries an instance id so the plane can tell that relay's next socket from a different relay. Same relay means same instance id.
- The plane accepts an instance id of at most 128 bytes. A longer id is rejected with WebSocket code 4002 and the reason `instance id is too long; max is 128 bytes`. That relay logs the error and does not redial, because the id is not in this file and a changed `name` or `plane_url` would dial with the same id.
- `label` is the display name. `program` is the product name, such as `opencode`.

Hello rejections also use WebSocket code 4003 (`link name must be a short slug`) and 4004 (`uplink is not allowed`). Like 4001, both park the relay until restart or a `name`/`plane_url` change; label or program edits do not retry. For 4004, ask the plane operator to allow the uplink, then restart the relay. Code 4002 stays parked until restart even if the link target changes. Other closes and transient failures retry after 500ms. `Pont.AgentSocketProtocol` defines these shared codes, reasons, and the instance-id limit.

The plane listens only on `127.0.0.1`. On another machine, set `plane_url` to an address that machine can reach.

`/acp`, `/agent`, and `/status` require the token. A caller sends `Authorization: Bearer`, or `?token=` on the URL. The uplink sends the header. `/health` stays open.

The workspace is `$HOME/.pont/workspace`. `Pont.OpenCode` runs `opencode` from `PATH`, or `$HOME/.local/bin/opencode`.

For `session/new` and `session/load`, the agent relay fills a missing, null, or empty `cwd` with its workspace before forwarding to the agent. An explicit `cwd` is passed through unchanged and refers to a path on the agent's machine.

## Tests

`mix test` does not start OpenCode. `PONT_BIN=./burrito_out/pont_linux OPENCODE_BIN=/path/to/opencode mix test --only wrapped` starts the wrapped binary, asks OpenCode to write a page, and checks that page. Set `OPENCODE_BIN` when `opencode` is not on `PATH`.
