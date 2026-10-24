# Pont

> Pont means bridge in French.

Pont proxies [Agent Client Protocol](https://agentclientprotocol.com) traffic between a client and one agent. The plane accepts the app connection. The agent relay opens the agent. The uplink dials the agent socket.

ACP is JSON-RPC. The agent writes JSONL on its standard output. Pont sends one JSON value in each WebSocket text frame.

## Run Pont

You need Elixir 1.17. To run an agent, you also need the `opencode` binary.

```sh
mix deps.get
mix run --no-halt
```

That starts the plane and the agent relay. Arguments go after `--`.

```sh
mix run --no-halt -- plane --port 8090
mix run --no-halt -- agent --token 'the-token'
```

`plane` is the plane alone. `agent` is the relay alone. The relay reads `$HOME/.pont/agent.link.json` for its name and plane URL. `--port` is the plane's port. `--token` is the single-player token. A plane with no token mints one and prints `pont agent --token '…'`.

## Routes

The plane serves these paths on port 8090.

| Path | Response |
|---|---|
| `GET /health` | The body is `ok`. |
| `GET /status` | JSON with the listen address and the connected agents. |
| `GET /acp` | WebSocket for an ACP client. |
| `GET /agent` | WebSocket the uplink dials. |

A client connects to `ws://127.0.0.1:8090/acp`. It sends ACP requests such as `session/new`, `session/load`, and `session/prompt`. Pont returns a permission question only to the client that started that turn.

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

`name` is the agent id. `label` is the display name. `program` is the product name, such as `opencode`.

The plane listens only on `127.0.0.1`. On another machine, set `plane_url` to an address that machine can reach.

`/acp`, `/agent`, and `/status` require the token. A caller sends `Authorization: Bearer`, or `?token=` on the URL. The uplink sends the header. `/health` stays open.

The workspace is `$HOME/.pont/workspace`. `Pont.OpenCode` runs `opencode` from `PATH`, or `$HOME/.local/bin/opencode`.

## Tests

`mix test` does not start OpenCode.

`mix test --only integration` starts `opencode acp` and asks it to write a page. The test parses that page and checks the document.
