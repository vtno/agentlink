# Pont

Pont is an Elixir control plane and sidecar for [Agent Client Protocol](https://agentclientprotocol.com). An ACP client talks to Pont. Pont forwards that session to a named agent. The sidecar owns the agent process and dials the plane.

The plane and the sidecar can share one BEAM, or run as two BEAM nodes. They still use the same WebSocket either way. The plane listens on `127.0.0.1` only, so a second machine cannot reach it until that bind changes.

## Pieces

| Piece | Role |
|---|---|
| Plane | WebSocket proxy. Apps connect here. It routes each session to one named agent. |
| Sidecar | Supervises one agent and dials the plane. |
| Harness | How the sidecar opens the agent. Production runs `opencode acp`. |

ACP itself is JSON-RPC. On the agent it is JSONL over stdio. On the wire to the plane it is one JSON value per WebSocket text frame.

## Run

Requires Elixir 1.17 and an `opencode` binary for the agent mode.

```sh
mix deps.get
PONT_MODE=all mix run --no-halt
```

`all` starts both in one BEAM. The sidecar still connects to the plane over the WebSocket. `PONT_MODE=plane` starts only the proxy. `PONT_MODE=agent` starts only the sidecar, which dials `PONT_PLANE_URL`.

## Connect

| Path | Who |
|---|---|
| `GET /health` | Liveness. Body is `ok`. |
| `GET /status` | JSON. The listen address and the agents currently dialed in. |
| `GET /acp` | WebSocket for an ACP client. |
| `GET /agent` | WebSocket for a sidecar. |

A client is a normal ACP peer on `ws://127.0.0.1:8090/acp`. It sends `session/new`, `session/load`, `session/prompt`, and the rest. The plane picks the agent from the session and forwards the frames. Replies and live updates come back on the same socket. A permission question goes only to the client that started that turn.

## Name an agent

The sidecar reads `agent.link.json` when it dials:

```json
{
  "name": "opencode",
  "label": "this machine",
  "plane_url": "ws://127.0.0.1:8090/agent"
}
```

`name` is the id clients see. `label` is the display name. The path is fixed at `/workspace/bridge/agent.link.json`.

## Environment

| Variable | Default | Used by |
|---|---|---|
| `PONT_MODE` | `all` | `plane`, `agent`, or `all` |
| `PONT_PORT` | `8090` | Plane listen port |
| `PONT_PLANE_URL` | `ws://127.0.0.1:8090/agent` | Sidecar dial address. Overrides `plane_url` in the link file. |
| `PONT_RUNTIME_NAME` | from the link file, else `opencode` | Agent id. Overrides `name` in the link file. |
| `PONT_WORKDIR` | `/workspace/agent-workdir` | Working directory of the agent process. |
| `OPENCODE_BIN` | `/workspace/node_modules/.bin/opencode` | The `opencode` executable. The sidecar runs it as `opencode acp`. |

## Tests

```sh
mix test
```

That suite does not start OpenCode. `test/test_helper.exs` excludes `:integration`.

The live test starts a real `opencode acp` and asks it to write a page:

```sh
mix test --only integration
```
