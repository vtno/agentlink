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
| `GET /status` | JSON with the listen address and the connected agents. |
| `GET /acp` | WebSocket for an ACP client. |
| `GET /agent` | WebSocket the uplink dials. |

A client connects to `ws://127.0.0.1:8090/acp`. It sends ACP requests such as `session/new`, `session/load`, and `session/prompt`. Pont returns a permission question only to the client that started that turn. File and terminal requests go to that client only when its own `initialize` advertised them. Otherwise the agent is answered with JSON-RPC `-32601`.

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

`name` is the agent id. One plane keeps a single uplink for each name. The first uplink to register a name keeps the socket. A later hello for that name is rejected with WebSocket code 4001 and the reason `name "<name>" is in use; stop the other relay or change name`. That relay logs the clash and does not redial until `name` or `plane_url` in this file changes. When the holder disconnects, the name is free for a new dial. `label` is the display name. `program` is the product name, such as `opencode`.

The plane listens only on `127.0.0.1`. On another machine, set `plane_url` to an address that machine can reach.

`/acp`, `/agent`, and `/status` require the token. A caller sends `Authorization: Bearer`, or `?token=` on the URL. The uplink sends the header. `/health` stays open.

The workspace is `$HOME/.pont/workspace`. `Pont.OpenCode` runs `opencode` from `PATH`, or `$HOME/.local/bin/opencode`.

## Tests

`mix test` does not start OpenCode. `PONT_BIN=./burrito_out/pont_linux OPENCODE_BIN=/path/to/opencode mix test --only wrapped` starts the wrapped binary, asks OpenCode to write a page, and checks that page. Set `OPENCODE_BIN` when `opencode` is not on `PATH`.
