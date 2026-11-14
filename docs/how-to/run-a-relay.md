# Run a relay

Run the relay on the machine that has the agent. The relay reads a link file, opens `command`, and dials the plane. It does not listen. `agentlink relay --port 8090` exits with status 1 and prints `agentlink relay does not listen.`

## Start one relay

[Set the token](set-the-token.md) on this machine. Use the same token as the plane.

Create `$HOME/.agentlink/agent.link.json`. [Add an agent](add-an-agent.md) has `command` and `args` for OpenCode, Codex, Claude Code, and Kimi. [Link file](../reference/link-file.md) lists every field. For a plane on this same machine, `plane_url` is `ws://127.0.0.1:8090/agent`. For a plane elsewhere, set `plane_url` from [Reach a plane on another machine](reach-another-machine.md).

```sh
agentlink relay
```

The relay prints `AgentLink is using the configured token.` The next line is `The uplink will dial the plane_url in the link file.` When the plane accepts the hello, the plane prints `Uplink connected:` followed by the link name and the label.

If the link file is missing, the process prints `No link file at` and the path, then exits with status 1. If `command` is a bare name that is not on `PATH`, the process prints `could not find` and that name, then exits with status 1.

## Point at a different link file

`--link` selects the file for this process. Use it to run a second relay beside the default file. Give the two files different `name` values. AgentLink turns `name` into a slug, so `Lab Box` and `lab-box` are the same name.

```sh
agentlink relay --link /path/to/first.link.json
agentlink relay --link /path/to/second.link.json
```

Run each command in its own terminal. Both files use the same `plane_url` and the same token. When both uplinks are online, [Connect a client](connect-a-client.md) needs `--target` so the editor selects one.

## Keep agent logs off the console

The agent inherits the relay's standard error. With the default logger, AgentLink writes its own log to standard output. To store the agent's standard error in a file, redirect standard error.

```sh
agentlink relay --link /path/to/agent.link.json 2>agent.log
```

Startup errors from the relay go to that file too. Agent output can contain account details, so restrict who can read the file.

A change to only `command` or `args` does not replace the running agent. Stop the relay and start it again. [Lifecycle](../explanation/lifecycle.md) describes that restart. [Reconnect a relay](reconnect-a-relay.md) describes a parked uplink.

From a clone, the same command is `mix run --no-halt -- relay`.
