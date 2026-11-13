# Run an always-on orchestrator

Run the plane on the orchestrator's machine and the agent relay on the user's machine. AgentLink does not ship an orchestrator or an ACP driver. Use an ordinary ACP client, such as Zed, to drive the agent.

## Start the plane

1. Create a token as shown in [Run AgentLink from source](../README.md#run-agentlink-from-source). Transfer the same token to the user's machine through a secure channel.
2. Set `AGENTLINK_TOKEN` or put the token in `$HOME/.agentlink/token` with mode 0600.
3. Start the plane on the orchestrator's machine.

	```sh
	agentlink plane
	```

The plane listens on `127.0.0.1:8090`. Do not publish the plane's listen port. Never pass the token on a command line.

## Connect the relay

Choose a route to the plane.

For an SSH tunnel, run `ssh -L 8090:127.0.0.1:8090 plane-host` on the user's machine. Set `plane_url` to `ws://127.0.0.1:8090/agent`.

For Tailscale raw TCP, run `tailscale serve --tcp 8443 tcp://127.0.0.1:8090` on the plane's machine. Set `plane_url` to `ws://HOST:8443/agent`, with `HOST` replaced by the plane's Tailscale host. Raw TCP forwarding does not terminate TLS. See the [Tailscale Serve reference](https://tailscale.com/kb/1242/tailscale-serve).

For Tailscale HTTPS Serve, follow [Option 2: Tailscale serve](../README.md#option-2-tailscale-serve). HTTPS Serve terminates TLS. Set `plane_url` to `wss://HOST/agent`, with `HOST` replaced by the plane's Tailscale host.

For a TLS reverse proxy, follow [Option 3: Caddy or another TLS reverse proxy](../README.md#option-3-caddy-or-another-tls-reverse-proxy). Set `plane_url` to `wss://plane.example.com/agent`, with the proxy's host in place of `plane.example.com`.

Then start the relay on the user's machine.

1. Set `AGENTLINK_TOKEN` or put the same token in `$HOME/.agentlink/token` with mode 0600.
2. Create `$HOME/.agentlink/agent.link.json`. Set `name`, `command`, `args`, and `plane_url` for the agent and the chosen route. See [Link file](../README.md#link-file) for the fields.
3. Run `agentlink relay`.

For several relays, give each link a distinct slug. AgentLink turns each `name` into a slug, so names such as `Lab Box` and `lab-box` collide. See [Link file](../README.md#link-file) for multiple relays.

## Check the link

On the plane's machine, check `GET /health`. The endpoint needs no token.

```sh
curl -fsS http://127.0.0.1:8090/health
```

Check `GET /status` with the token. The `header` line uses curl config syntax and assumes a single-line token without spaces, double quotes, or backslashes, such as the hex token from [Run AgentLink from source](../README.md#run-agentlink-from-source). Turn off shell tracing before running it.

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$HOME/.agentlink/token")" | curl -fsS --config - http://127.0.0.1:8090/status
```

If you use `AGENTLINK_TOKEN` instead of the token file, replace `$(cat "$HOME/.agentlink/token")` with `$AGENTLINK_TOKEN` inside the double quotes. AgentLink turns the link's `name` into a slug, and `/status` shows that slug. Confirm that `runtimes` contains the target slug. Each relay needs a distinct slug. The token used for this check must match the plane's token.

## Connect the orchestrator

Configure your ACP client to run `agentlink connect --target NAME` over stdio. Replace `NAME` with the online link name. Set the plane URL with `--plane`, `AGENTLINK_PLANE`, or the `plane` field in `$HOME/.agentlink/config`. Set `AGENTLINK_TOKEN` or use the token file.

To use `AGENTLINK_TARGET` or the config file's `target` field, omit `--target`. If several agents are online and you select none, the error says `Several agents are online: <names>. Pass --target NAME.` The error lists the actual names. See [Command line](../README.md#command-line) for precedence and configuration.

## Connect to `/acp` directly

To use the WebSocket without `agentlink connect`, connect your ACP client to `/acp`. Send the token in the `Authorization: Bearer` header. Send `runtime/list`, then send `runtime/select` with the chosen name in `params.name`. See [Client socket](../README.md#client-socket) for the messages.

## Protect the token

Never print or log the token. Do not put it in a command-line argument. The default access policy uses one shared token today. Per-machine tokens and revocation are future work.

A proxy can log `?token=`. Turn query logging off before you proxy the plane. See [Security model](../README.md#security-model).
