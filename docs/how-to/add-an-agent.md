# Add an agent

The relay opens whatever program `command` names. It passes `args` unchanged. AgentLink does not download an adapter, does not insert `acp` for you, and does not set product-specific environment variables. Install the agent on the relay machine, then put its executable in the link file.

`command` is a bare name on `PATH`, or an absolute path. A relative path is an error. `args` is a list of strings. `[]` is valid. `program` is a label for humans and status output. It does not choose `command`. An `env` key is an error, so put the agent's own credentials in the agent's config on this machine, not in the link file.

[Link file](../reference/link-file.md) lists the other fields. [Run a relay](run-a-relay.md) starts the process. Use a distinct `name` for each relay on one plane.

## OpenCode

Install OpenCode so `opencode` is on `PATH`.

```json
{
	"name": "opencode",
	"label": "this machine",
	"program": "opencode",
	"plane_url": "ws://127.0.0.1:8090/agent",
	"command": "opencode",
	"args": ["acp"]
}
```

## Kimi

Install the Kimi Code CLI so `kimi` is on `PATH`. The ACP argument is the same shape as OpenCode.

```json
{
	"name": "kimi",
	"label": "this machine",
	"program": "kimi",
	"plane_url": "ws://127.0.0.1:8090/agent",
	"command": "kimi",
	"args": ["acp"]
}
```

## Codex

Install `@agentclientprotocol/codex-acp`. Set `command` to the `codex-acp` executable. A local install puts that file at `node_modules/.bin/codex-acp`. Use an absolute path when the bare name is not on `PATH`. `args` is `[]`.

```json
{
	"name": "codex",
	"label": "Codex",
	"program": "codex",
	"plane_url": "ws://127.0.0.1:8090/agent",
	"command": "/absolute/path/to/codex-acp",
	"args": []
}
```

Do not use `@zed-industries/codex-acp`. That package is deprecated and fails prompts. Do not set `command` to `codex`. `codex app-server` speaks Codex's own protocol, not ACP.

Sign in with the Codex CLI on the relay machine before you start the relay. The relay passes the process environment through, except `AGENTLINK_WINDOWS_START`, and the link file cannot hold an `env` object.

## Claude Code

Install a standalone release of `@agentclientprotocol/claude-agent-acp`. The archive contains `claude-agent-acp` and `claude`. Keep those two files in the same directory. The archive does not need Node. Set `command` to the absolute path of `claude-agent-acp` and set `args` to `[]`.

```json
{
	"name": "claude",
	"label": "Claude",
	"program": "claude",
	"plane_url": "ws://127.0.0.1:8090/agent",
	"command": "/absolute/path/to/claude-agent-acp",
	"args": []
}
```

Do not set `command` to `claude`. Configure Claude credentials on the relay machine before you start the relay. The link file cannot pass an `env` object.

To use a `claude` binary you already installed, the adapter reads `CLAUDE_CODE_EXECUTABLE` from the environment. Export it in the shell that starts the relay. Do not put it in the link file.
