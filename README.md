# AgentLink

AgentLink proxies [Agent Client Protocol](https://agentclientprotocol.com) messages between an editor and an agent, so you choose each one separately. The agent stays on your machine. A client reaches that agent through the plane.

`agentlink plane` accepts connections. `agentlink relay` opens one agent and dials the plane. `agentlink connect` is the program an editor runs. [Architecture](docs/explanation/architecture.md) describes how those three processes relate.

## Install a release

A release for a tag that starts with `v` includes one archive for each target and a `SHA256SUMS` file. Linux and macOS archives are gzip tarballs. The Windows archive is a zip file. The file names are `agentlink-linux-x86_64.tar.gz`, `agentlink-linux-aarch64.tar.gz`, `agentlink-macos-x86_64.tar.gz`, `agentlink-macos-arm64.tar.gz`, and `agentlink-windows-x86_64.zip`. `SHA256SUMS` lists the SHA-256 digest of each archive, one archive per line, in the format `sha256sum` writes.

The machine that runs the release does not need Elixir. The archive includes its own Erlang runtime. [Release packaging](docs/explanation/release.md) explains why the runtime is packed that way.

1. Download `SHA256SUMS` and the archive for your machine.
2. Verify the archive before you unpack it.
3. Unpack the archive in an empty directory.
4. Run `bin/agentlink`. On Windows, run `bin/agentlink.bat`.

On Linux or macOS, run the check in the directory that contains `SHA256SUMS` and every archive listed in that file.

```sh
sha256sum -c SHA256SUMS
```

On Windows, run `(Get-FileHash -Algorithm SHA256 agentlink-windows-x86_64.zip).Hash.ToLower()`. Compare that hex with the hex at the start of the matching line in `SHA256SUMS`.

Create a token before the first start. [Set the token](docs/how-to/set-the-token.md) has the steps. [Stop AgentLink](docs/how-to/stop-agentlink.md) covers a release whose distribution is off.

## Run from a clone

This repository is tested with Elixir 1.20.4 and Erlang 29.1.2. `mix.exs` requires `~> 1.17`, so Mix accepts Elixir 1.17 or a later 1.x release.

1. Run `mix deps.get`.
2. Run `MIX_ENV=prod mix release`.
3. Add `_build/prod/rel/agentlink/bin` to `PATH`, or call `bin/agentlink` by that path.

The walkthrough below uses `mix run` and does not need the release. Pass AgentLink words after `--`.

```sh
mix run --no-halt -- --help
```

## Run a plane and a relay on one machine

We start the plane and one relay on this computer, and we see that relay in `GET /status`. The relay command in this walkthrough is OpenCode. If you want Codex, Claude Code, or another adapter, follow [Add an agent](docs/how-to/add-an-agent.md) and then come back to the status check.

These steps use `mix run` from a clone. With a release on `PATH`, run `agentlink` instead of `mix run --no-halt`.

### Create a token

This command needs OpenSSL. It refuses to replace a token file that already exists.

```sh
mkdir -p "$HOME/.agentlink"
(umask 077; set -C; openssl rand -hex 32 > "$HOME/.agentlink/token") &&
	chmod 600 "$HOME/.agentlink/token"
```

The file mode is `600`. Only the owner can read it and write it. The file is a single line of hex. Startup text does not include that line.

### Write the link file

Save this object as `$HOME/.agentlink/agent.link.json`.

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

`command` is the program the relay opens. `args` is the argument list. OpenCode's ACP mode is the argument `acp`.

### Start AgentLink

```sh
mix deps.get
mix run --no-halt
```

`mix run --no-halt` starts the plane and the relay together. The process prints `AgentLink is using the configured token.` and `The agent relay on this machine is starting.` The token is not in that text. The log contains `opened AgentLink.Agent.Process`. The plane then prints this line.

```text
Uplink connected: opencode (this machine).
```

If OpenCode is not on `PATH`, the process prints `could not find opencode` and exits with status 1. A listener line can appear before that exit. Install OpenCode, or change `command` as described in [Add an agent](docs/how-to/add-an-agent.md), and start again.

### Check the plane

In a second terminal, check the health route. It does not use the token.

```sh
curl -fsS http://127.0.0.1:8090/health
```

The body is `ok`.

Check status with the token. Turn shell tracing off first. The `header` line uses curl config syntax. The token must be one line and must not contain a space, a double quote, or a backslash. The hex file from the step above has that shape.

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$HOME/.agentlink/token")" | curl -fsS --config - http://127.0.0.1:8090/status
```

The JSON object has `plane` set to `127.0.0.1:8090`. `runtimes` contains one entry whose `name` is `opencode`.

An editor talks to that runtime through `agentlink connect`. [Connect a client](docs/how-to/connect-a-client.md) is that step.

## Tasks

Each guide is one task.

- [Set the token](docs/how-to/set-the-token.md) creates the bearer token and chooses where it is stored.
- [Start a plane](docs/how-to/start-a-plane.md) runs the listener on its own.
- [Run a relay](docs/how-to/run-a-relay.md) opens an agent, including a second agent with `--link`.
- [Connect a client](docs/how-to/connect-a-client.md) points an editor at the plane.
- [Add an agent](docs/how-to/add-an-agent.md) sets `command` and `args` for OpenCode, Codex, Claude Code, or Kimi.
- [Reach a plane on another machine](docs/how-to/reach-another-machine.md) uses an ssh tunnel, Tailscale, or a TLS proxy.
- [Reconnect a relay](docs/how-to/reconnect-a-relay.md) covers a dropped dial and a parked uplink. There is no ping-interval setting.
- [Stop AgentLink](docs/how-to/stop-agentlink.md) stops a release when distribution is off.
- [Run an always-on orchestrator](docs/orchestrator.md) puts the plane on one machine and the relay on another.

## Explanation

These pages describe why AgentLink is built this way.

- [Architecture](docs/explanation/architecture.md) covers the plane, the relay, and the client.
- [Protocol paths](docs/explanation/protocol.md) covers `/acp` and `/agent`.
- [Lifecycle](docs/explanation/lifecycle.md) covers startup, supervision, and restarts.
- [Reconnect and keepalive](docs/explanation/reconnect.md) covers retry, parking, and WebSocket ping frames.
- [Security model](docs/explanation/security.md) covers the single token and the localhost listener.
- [Release packaging](docs/explanation/release.md) covers the runtime swap and why distribution is off.

## Reference

These pages list flags, files, routes, and protocol results.

- [Command line](docs/reference/command-line.md) lists commands, flags, and exit statuses.
- [Configuration](docs/reference/configuration.md) lists environment variables and the config file.
- [Link file](docs/reference/link-file.md) lists the fields in `agent.link.json`.
- [HTTP routes](docs/reference/http.md) lists `/health`, `/status`, `/acp`, and `/agent`.
- [Client and uplink protocol](docs/reference/protocol.md) lists hello fields, close codes, and ACP results.

## Contributor notes

Read the matching page when you change that part of the code.

- [Glossary](docs/glossary.md) names a connection, a process, or a module.
- [Structs](docs/structs.md) says when a value is a struct.
- [GenServers](docs/genservers.md) says where a client call sits.
- [Names](docs/names.md) says how modules and pid fields are named.
- [Agent process](docs/agent.md) describes how the relay opens, stops, and reaps an agent.
- [Release script interfaces](.github/scripts/README.md) lists the packager commands.
- [Contributing](CONTRIBUTING.md) lists format, compile, and test commands.

## License

Copyright 2026 Tino Thamjarat and Thamtech Co., Ltd. AgentLink is licensed under the Apache License, Version 2.0. The license identifier in `mix.exs` is `Apache-2.0`. The full text is in `LICENSE`.
