---
name: agentlink-orchestrator
description: Use when you run an AgentLink plane as an always-on orchestrator and drive an agent on a user's machine through it.
---

# Run an AgentLink orchestrator

AgentLink does not ship an orchestrator or an ACP driver. Use an ACP client to drive the agent.

## Start and check the plane

1. Set `AGENTLINK_TOKEN` or use `$HOME/.agentlink/token` with mode 0600. Use the same token as the user's relay.
2. Start `agentlink plane` on the orchestrator's machine. If you start it in the background, record `$!`.
3. Check the unauthenticated health endpoint.

	```sh
	curl -fsS http://127.0.0.1:8090/health
	```

4. Check status with the token in the `Authorization: Bearer` header. Turn off shell tracing first. This example uses the hex token from [Run AgentLink from source](../../README.md#run-agentlink-from-source).

	```sh
	printf 'header = "Authorization: Bearer %s"\n' "$(cat "$HOME/.agentlink/token")" | curl -fsS --config - http://127.0.0.1:8090/status
	```

	If you use `AGENTLINK_TOKEN` instead of the token file, replace `$(cat "$HOME/.agentlink/token")` with `$AGENTLINK_TOKEN` inside the double quotes. Confirm that `runtimes` contains the target link's `name`.

## Connect to the agent

1. Set the plane URL with `--plane`, `AGENTLINK_PLANE`, or `plane` in `$HOME/.agentlink/config`.
2. Run `agentlink connect --target NAME` as the ACP client's stdio command. Replace `NAME` with the online link name.
3. Use `AGENTLINK_TARGET` or the config file's `target` field instead of `--target` if needed. See [Command line](../../README.md#command-line) for precedence.

## Run an ACP session

1. Send `initialize`, then `session/new`.
2. Send `session/prompt` with the returned session ID. Read `session/update` notifications and answer `session/request_permission` requests.
3. To stop a running turn, send the `session/cancel` notification. Answer pending permission requests as described in the [ACP specification](https://agentclientprotocol.com).
4. Before closing a session with a running turn, send `session/cancel`. Send `session/close` to leave the session. The plane answers `session/close` and drops the client's subscription. It does not forward the request to the agent.

The plane also handles `session/list`, `session/load`, and `session/resume` itself. See [Client socket](../../README.md#client-socket) for their behavior.

## Protect the token and processes

- Never print or log the token. Never pass it on a command line.
- Never list other processes' command lines with `ps`, `pgrep -a`, or `/proc/*/cmdline`. They can contain secrets.
- Stop only processes you started, using the pid you recorded. Do not restart the user's relay.
