# Command line

`agentlink --help` and `agentlink -h` print the usage to standard output and exit with status 0. Any other first word that is not a command below is a usage error. The usage is written to standard error and the process exits with status 1. `agentlink plane --help` is that error. `--help` is recognized only as the first word.

The usage text is:

```text
agentlink [--port PORT] [--token TOKEN]
agentlink plane [--port PORT] [--token TOKEN]
agentlink relay [--link PATH] [--token TOKEN]
agentlink connect [--plane URL] [--target NAME] [--token TOKEN]

Set AGENTLINK_TOKEN or use $HOME/.agentlink/token to keep the token out of the command line.
```

## Commands

| Command | What it starts |
| --- | --- |
| `agentlink` | The plane and the relay. The mode is `:all`. |
| `agentlink plane` | The plane. The link file is not read. |
| `agentlink relay` | The relay. The process does not listen. |
| `agentlink connect` | The client relay. The plane, the agent relay, and the link file are not used. |

An empty argument list is the same command as `agentlink`. A release binary with no words also leaves the compiled mode in place, and that mode is `:all`.

`plane` and the no-subcommand form accept a leading flag list. `relay` and `connect` do not. Unknown flags are a usage error.

## Flags

`--port` is an integer from 1 to 65535. The default is 8090. A value outside that range prints `port must be from 1 to 65535.` and the usage, then exits with status 1. `agentlink relay` rejects `--port` and prints `agentlink relay does not listen.` before the usage.

`--token` is the bearer token for that process. An empty string is a usage error. For the plane, the relay, and combined mode, the flag is stored as written and is not trimmed. `AGENTLINK_TOKEN` and the token file are trimmed. For `agentlink connect`, the flag, the environment variable, and the file are all trimmed.

`--link` is the link file for this relay. It applies to `agentlink relay` only. An empty string is a usage error.

`--plane` is the plane WebSocket URL for `agentlink connect`. A URL with no path uses `/acp`. An empty string is a usage error.

`--target` is the agent name for `agentlink connect`. The bytes are compared as given. `Alice` and `alice` are different names. An empty string is a usage error.

The listener binds `127.0.0.1` only. The scheme on that socket is HTTP, so the plane's own URL is `ws://127.0.0.1:<port>/agent`.

There is no flag for the ping interval or the pong timeout. [Configuration](configuration.md) lists `AGENTLINK_WEBSOCKET_PING_INTERVAL` and `AGENTLINK_WEBSOCKET_PONG_TIMEOUT`. [Set the keepalive](../how-to/set-the-keepalive.md) is the procedure.

## Where values come from

For `agentlink`, `agentlink plane`, and `agentlink relay`, the token comes from `--token`, then `AGENTLINK_TOKEN`, then `$HOME/.agentlink/token`. A value that is empty after trimming is unset. The file must be a regular file in mode `0600`, `0400`, `0200`, or `0000`. A missing token exits with status 1. The message names `--token`, `AGENTLINK_TOKEN`, and the token path.

`agentlink connect` resolves `--plane`, `--target`, and `--token` separately. For each one, a flag that has text wins over the environment variable, and an environment variable that has text wins over the file. The variables are `AGENTLINK_PLANE`, `AGENTLINK_TARGET`, and `AGENTLINK_TOKEN`. The files are in [Configuration](configuration.md).

`agentlink` and `agentlink plane` do not read `AGENTLINK_PLANE`. `agentlink relay` reads the plane URL from the link file.

## Exit status

| Status | When |
| --- | --- |
| 0 | `--help` or `-h` as the first word. `agentlink connect` stops because standard input closed, including when it was already closed at start. |
| 1 | A usage error, a bad port, a missing token, a missing plane URL, a missing or invalid link file, a `command` that cannot be opened, or a client relay shutdown other than closed standard input. |

`agentlink connect` on `SIGTERM` exits with status 1. The log line is `SIGTERM received - shutting down`.

`mix run --no-halt --` passes every following word to this same parser.
