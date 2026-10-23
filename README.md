# Pont

> Pont means bridge in French.

Pont proxies [Agent Client Protocol](https://agentclientprotocol.com) traffic between a client and one agent. The plane accepts the client. The agent relay opens the agent. The uplink dials the plane.

ACP is JSON-RPC. The agent writes JSONL on its standard output. Pont sends one JSON value in each WebSocket text frame.

## Run Pont

You need Elixir 1.17. To run an agent, you also need the `opencode` binary.

```sh
mix deps.get
PONT_MODE=all mix run --no-halt
```

`all` starts the plane and the agent relay in one BEAM. The plane listens only on `127.0.0.1`.

To start the plane alone, set `PONT_MODE=plane`. For the agent relay alone, set `PONT_MODE=agent`.

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

`Pont.Link` reads `$HOME/.pont/agent.link.json`. The agent relay refuses to start until that file exists.

```json
{
  "name": "opencode",
  "label": "this machine",
  "plane_url": "ws://127.0.0.1:8090/agent"
}
```

`name` is the agent id. `label` is the display name.

## Environment

`PONT_RUNTIME_NAME` overrides `name` in the link file. `PONT_PLANE_URL` overrides `plane_url`. `PONT_MASTER_TOKEN` is the single-player token. If it is unset, the plane mints one for this process and prints it. `/acp`, `/agent`, and `/status` then require that token. A caller sends `Authorization: Bearer`, or `?token=` on the URL. The uplink sends the header. `/health` stays open.

| Variable | Default |
|---|---|
| `PONT_MODE` | `all` |
| `PONT_PORT` | `8090` |
| `PONT_PLANE_URL` | `ws://127.0.0.1:8090/agent` |
| `PONT_RUNTIME_NAME` | `opencode`, or `name` from the link file |
| `PONT_WORKDIR` | `$HOME/.pont/workspace` |
| `OPENCODE_BIN` | `opencode` on `PATH`, otherwise `$HOME/.local/bin/opencode` |
| `PONT_MASTER_TOKEN` | minted for this process when unset |

`OPENCODE_BIN` is the `opencode` executable. `Pont.OpenCode` runs it as `opencode acp`.

## Tests

`mix test` does not start OpenCode.

`mix test --only integration` starts `opencode acp` and asks it to write a page.
