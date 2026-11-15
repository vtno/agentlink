# Set the keepalive

The uplink, `agentlink connect`, and the plane sockets send a WebSocket ping while the socket is open. The default interval is 30000 milliseconds. The default wait for a pong is 10000 milliseconds. [Reconnect and keepalive](../explanation/reconnect.md) explains why a vanished host needs that ping.

## Set the interval and the timeout

Set both variables for the process, then start it. `agentlink` with no subcommand runs the plane and the uplink in that same VM, so the variables apply to both. `agentlink plane` and `agentlink relay` are separate processes. Set the variables in each environment. Use a positive integer of milliseconds. The largest value is 4294967295. The dial reads the variables once, when the dial process starts. Each plane socket reads them when that socket starts.

```sh
AGENTLINK_WEBSOCKET_PING_INTERVAL=15000 \
AGENTLINK_WEBSOCKET_PONG_TIMEOUT=5000 \
agentlink plane
```

`agentlink relay` and `agentlink connect` take the same variables. `agentlink connect` is a different process. Set the variables in the environment that launches the editor command.

A blank value is skipped. A value that is not a positive integer in that range is skipped. The dial logs `transport keepalive`, the source name, and `ignored`. A plane socket logs `plane keepalive`, the source name, and `ignored`. A binary longer than 64 bytes keeps the first 64 bytes and then `...`. The process uses the next source.

The next source is the `:agent_link` application env. The keys are `:websocket_ping_interval` and `:websocket_pong_timeout`. `config/config.exs` sets them to 30000 and 10000. There is no `config/runtime.exs`. To change a key, edit that file and build again. [Configuration](../reference/configuration.md) lists the full order. That page also lists the dial start options and the `init/1` options. The CLI does not expose them.

On Linux the dial sets `TCP_USER_TIMEOUT` to the interval plus the pong timeout, and not above 2147483647 milliseconds. You do not set that option yourself. The plane sockets do not set it.

## Read the log

A valid value is not printed. An ignored value is the warning above. A missed pong on the dial logs `transport keepalive expired`. The uplink then dials again. After a runtime is selected, `agentlink connect` logs `client relay plane socket closed code=1006` and `plane closed`, and it exits with status 1.

A missed pong on the plane logs `plane keepalive expired`. The socket closes with code 1001 and the reason `keepalive pong timeout`. The runtime drops off `/status`. A client with a request on that runtime receives JSON-RPC error `-32000` and the message `runtime disconnected`. When a client socket misses a pong, the plane drops that client's sessions and queued prompts.
