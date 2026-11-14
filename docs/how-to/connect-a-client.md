# Connect a client

Point an editor at a plane that already has a relay online. `agentlink connect` does not start the plane, does not start the relay, and does not read the link file. The editor runs this command as its ACP agent and owns standard input and standard output.

## Select the plane and the agent

[Set the token](set-the-token.md) for this command. Then set the plane URL. A URL with no path uses `/acp`.

```sh
agentlink connect --plane ws://127.0.0.1:8090/acp --target opencode
```

`--target` is the link name the plane shows in `GET /status`, after slug rules. When exactly one agent is online, you can omit `--target` and the client relay selects that agent.

You can store the URL and the target so the editor's command stays `agentlink connect`. The flag wins over the environment variable, and the environment variable wins over the file. [Configuration](../reference/configuration.md) lists `AGENTLINK_PLANE`, `AGENTLINK_TARGET`, `AGENTLINK_TOKEN`, and `$HOME/.agentlink/config`.

```json
{
	"plane": "ws://127.0.0.1:8090/acp",
	"target": "opencode"
}
```

Save that object as `$HOME/.agentlink/config`. Do not add a `token` key.

## Recover when the command exits

A missing plane URL exits with status 1. The message begins `agentlink connect needs a plane URL.` A missing token exits with status 1. The message begins `agentlink connect needs a token.`

When no agent is online, the command exits with status 1 and the message says that no agent is online. When several agents are online and you did not select one, the message lists those names and says to pass `--target`. When the name is not online, the message names it, lists the online names, and says to pass `--target`.

When standard input closes, the command exits with status 0. That includes standard input that is already closed as the process starts.

To drive `/acp` from your own client instead of `agentlink connect`, send the token in the `Authorization: Bearer` header, then send `runtime/list` and `runtime/select`. [Client and uplink protocol](../reference/protocol.md) lists those messages.

From a clone, the same command is `mix run --no-halt -- connect`.
