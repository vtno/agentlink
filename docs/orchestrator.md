# Run an always-on orchestrator

Run the plane on the orchestrator's machine and the agent relay on the user's machine. AgentLink does not ship an orchestrator or an ACP driver. Use an ordinary ACP client, such as Zed, to drive the agent.

## Start the plane

1. Create a token with [Set the token](how-to/set-the-token.md). Copy that same token to the user's machine through a secure channel.
2. Set `AGENTLINK_TOKEN`, or put the token in `$HOME/.agentlink/token` with mode `0600`.
3. Start the plane on the orchestrator's machine.

	```sh
	agentlink plane
	```

The plane listens on `127.0.0.1:8090`. Do not publish that port. Do not pass the token on a command line.

## Connect the relay

Choose a route in [Reach a plane on another machine](how-to/reach-another-machine.md). An ssh tunnel uses `ws://127.0.0.1:8090/agent`. Tailscale TCP uses `ws://HOST:8443/agent`. Tailscale HTTPS and a TLS proxy use a `wss://` URL whose path is `/agent`.

Then start the relay on the user's machine.

1. Set `AGENTLINK_TOKEN`, or put the same token in `$HOME/.agentlink/token` with mode `0600`.
2. Create the link file. Set `name`, `command`, `args`, and `plane_url`. [Add an agent](how-to/add-an-agent.md) has the command for OpenCode, Codex, Claude Code, and Kimi. [Link file](reference/link-file.md) lists the fields.
3. Run `agentlink relay`.

For several relays, give each link a distinct slug. `Lab Box` and `lab-box` are the same name. [Run a relay](how-to/run-a-relay.md) shows `--link`.

## Check the link

On the plane's machine, check `GET /health`. The route needs no token.

```sh
curl -fsS http://127.0.0.1:8090/health
```

The body is `ok`.

Check `GET /status` with the token. Turn shell tracing off first. The `header` line uses curl config syntax and assumes a single-line token without spaces, double quotes, or backslashes. The hex file from [Set the token](how-to/set-the-token.md) matches that shape.

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$HOME/.agentlink/token")" | curl -fsS --config - http://127.0.0.1:8090/status
```

If you use `AGENTLINK_TOKEN` instead of the token file, replace `$(cat "$HOME/.agentlink/token")` with `$AGENTLINK_TOKEN` inside the double quotes. `/status` shows the slug of `name`. Confirm that `runtimes` contains the target slug. The token used for this check must be the plane's token.

## Connect the orchestrator

Configure the ACP client to run `agentlink connect --target NAME` over standard input and standard output. Replace `NAME` with the online link name. Set the plane URL with `--plane`, `AGENTLINK_PLANE`, or `plane` in `$HOME/.agentlink/config`. [Connect a client](how-to/connect-a-client.md) has the precedence. [Command line](reference/command-line.md) lists the exit statuses.

To use `AGENTLINK_TARGET` or the config file's `target` field, omit `--target`. If several agents are online and you select none, the error lists the names and says to pass `--target`.

To use the WebSocket without `agentlink connect`, connect the ACP client to `/acp`. Send the token in the `Authorization: Bearer` header. Send `runtime/list`, then send `runtime/select` with the chosen name in `params.name`. [Client and uplink protocol](reference/protocol.md) lists the messages.

## Protect the token

Do not print the token. Do not log it. Do not put it on a command line. The default access policy uses one shared token. Per-machine tokens and revocation are not implemented.

A proxy can log `?token=`. Turn query logging off before you proxy the plane. [Security model](explanation/security.md) describes the listener.
