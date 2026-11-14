# Lifecycle

Each command builds a different supervision tree. The split is there so a relay that cannot start does not, by itself, decide the fate of a plane that other relays still need.

## What each command starts

`agentlink` with no subcommand starts the plane supervisor and a separate relay supervisor. The relay supervisor is transient. It allows 5 restarts in 20 seconds. If it then stops, the plane supervisor keeps running.

`agentlink plane` starts only the plane supervisor. It does not read the link file.

`agentlink relay` starts the reaper and the relay under the application supervisor. That supervisor has the same budget of 5 restarts in 20 seconds. The relay is a direct child of the application. When that supervisor stops, the node stops. This command does not listen.

`agentlink connect` starts only the client relay. It does not prepare the token instructions, and it does not read the link file. A shutdown that means standard input closed exits with status 0. Any other shutdown message exits with status 1. A crash can be restarted by the supervisor. The supervisor's own stop exits with status 1.

The plane supervisor's children are the registry, the session directory, the plane, the uplink logger, and the HTTP listener. An agent relay is not among them. That supervisor also allows 5 restarts in 20 seconds.

## Failure at boot

A missing link file, a bad link file, or a `command` that cannot be opened stops that start. The command prints the message and exits with status 1. That first failure does not sit in a retry loop. The missing-file text begins `No link file at`. A bare name that `PATH` does not contain is `could not find` plus the name.

The 5 restarts matter after the relay is already up. If the agent exits, the supervisor starts the relay again. Each of those starts reads the link file again. A start that cannot open `command` counts toward the 5. In combined mode the relay supervisor then stops and the plane remains. In `relay` mode the application supervisor stops and the node stops.

## What a restart picks up

The running agent is the process opened at the last successful start. A later edit that changes only `command` or `args` leaves that process and the current uplink in place. The next start, including a supervisor restart, reads the new command.

The uplink reads the link file every 1000 milliseconds for `name`, `label`, `program`, and `plane_url`. Those fields are the link. `command` and `args` are not fields of the link, so a watch does not reopen the agent. [Reconnect and keepalive](reconnect.md) describes when a watch dials again.

The relay creates the workspace at `$HOME/.agentlink/workspace` if it is missing, and opens the agent with that directory as its working directory.

## How the agent process is stopped

On Linux the relay records process start times and signals the agent group on shutdown. On macOS and Windows it closes standard input and does not walk child processes. The reaper keeps any pid that survived, so the next start does not launch a second agent on top of one that is still alive. The timeouts, the signal sequence, and the reaper file are in [Agent process](../agent.md).

`SIGTERM` stops the plane, the relay, and the combined mode through the application shutdown. `agentlink connect` installs its own `SIGTERM` handler and exits with status 1. `SIGINT` opens the BREAK prompt in every mode. [Stop AgentLink](../how-to/stop-agentlink.md) is the operator procedure.
