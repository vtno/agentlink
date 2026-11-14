# Set the keepalive

The uplink and `agentlink connect` send a WebSocket ping while the dial is open. The default interval is 30000 milliseconds. The default wait for a pong is 10000 milliseconds. [Reconnect and keepalive](../explanation/reconnect.md) explains why a vanished host needs that ping.

## Set the interval and the timeout

Set both variables for the process that dials, then start it. `agentlink` with no subcommand runs the uplink in that same VM, so the variables apply there too. A plane process does not read them. Use a positive integer of milliseconds. The largest value is 4294967295. The dial reads the variables once, at startup.

```sh
AGENTLINK_WEBSOCKET_PING_INTERVAL=15000 \
AGENTLINK_WEBSOCKET_PONG_TIMEOUT=5000 \
agentlink relay
```

`agentlink connect` is a different process. Set the same variables in the environment that launches the editor command.

A blank value is skipped. A value that is not a positive integer in that range is skipped. The warning is `transport keepalive`, the source name, and `ignored`. A binary longer than 64 bytes keeps the first 64 bytes and then `...`. The process uses the next source.

The next source is the `:agent_link` application env. The keys are `:websocket_ping_interval` and `:websocket_pong_timeout`. `config/config.exs` sets them to 30000 and 10000. There is no `config/runtime.exs`. To change a key, edit that file and build again. [Configuration](../reference/configuration.md) lists the full order. That page also lists the start options. The CLI does not expose them.

On Linux the dial sets `TCP_USER_TIMEOUT` to the interval plus the pong timeout, and not above 2147483647 milliseconds. You do not set that option yourself.

## Read the log

A valid value is not printed. An ignored value is the warning above. A missed pong logs `transport keepalive expired`. The uplink then dials again. After a runtime is selected, `agentlink connect` logs `client relay plane socket closed code=1006` and `plane closed`, and it exits with status 1.
