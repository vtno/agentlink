# Set the token

Create one bearer token and give that same secret to the plane and to every relay. AgentLink does not create the token and does not print it.

## Create the file

This command needs OpenSSL. `set -C` makes the shell refuse to replace an existing file.

```sh
mkdir -p "$HOME/.agentlink"
(umask 077; set -C; openssl rand -hex 32 > "$HOME/.agentlink/token") &&
	chmod 600 "$HOME/.agentlink/token"
```

The file must be a regular file. AgentLink accepts mode `0600`, `0400`, `0200`, or `0000`. Any other permission bit is rejected. A file at mode `0644` fails with a message that names the path and says it must be `0600` or tighter.

Copy the file to each machine through a channel that already protects secrets. Do not pass the token as `--token`. The process list shows command-line arguments.

## Choose where the token comes from

`agentlink`, `agentlink plane`, and `agentlink relay` read the token from `--token`, then from `AGENTLINK_TOKEN`, then from `$HOME/.agentlink/token`. The first value that still has text after trimming wins. A blank value is unset.

`agentlink connect` uses the same order for its token. Its plane URL and target have their own sources, listed in [Configuration](../reference/configuration.md).

To use the environment variable for one shell, set it before the command.

```sh
export AGENTLINK_TOKEN="$(cat "$HOME/.agentlink/token")"
agentlink plane
```

A missing token makes the command exit with status 1. The message names `--token`, `AGENTLINK_TOKEN`, and the token path.

Do not put a `token` key in `$HOME/.agentlink/config`. That key is an error, and the error tells you to use the token file.

[Security model](../explanation/security.md) describes what the token authorizes and why the listener stays on `127.0.0.1`.
