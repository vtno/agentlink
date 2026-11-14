# Start a plane

Run the plane on the machine that should accept client and relay connections. This command does not read the link file and does not open an agent.

## Start the listener

[Set the token](set-the-token.md) first. Then start the plane.

```sh
agentlink plane
```

The listener binds `127.0.0.1` port `8090`. The plane prints `AgentLink is using the configured token.` and then waits for an uplink. The log line from the HTTP server names `127.0.0.1:8090`.

To use another port, pass `--port`. The port is an integer from 1 to 65535.

```sh
agentlink plane --port 8091
```

The plane's own URL for that port is `ws://127.0.0.1:8091/agent`. Use the same port in each relay's `plane_url`. [Command line](../reference/command-line.md) lists the other flags.

## Check that it is listening

`GET /health` does not use the token.

```sh
curl -fsS http://127.0.0.1:8090/health
```

The body is `ok`. Change `8090` if you set `--port`.

`GET /status` needs the token. With no relay connected, `runtimes` is an empty list. [HTTP routes](../reference/http.md) describes the JSON.

Do not publish port `8090`. A relay on another machine reaches the plane through a tunnel or a TLS proxy. [Reach a plane on another machine](reach-another-machine.md) has those routes.

From a clone, the same command is `mix run --no-halt -- plane`.
