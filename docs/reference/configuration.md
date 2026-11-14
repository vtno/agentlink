# Configuration

Values that select a plane, a target, or a token come from a flag, an environment variable, or a file. The flag wins, then the variable, then the file. A nil value, and a string that is empty after trimming, are unset. Stored strings are trimmed.

`agentlink connect` uses this order for the plane URL, the target, and the token. `agentlink`, `agentlink plane`, and `agentlink relay` use it for the token only.

## Environment variables

| Variable | Who reads it | Meaning |
| --- | --- | --- |
| `AGENTLINK_TOKEN` | Plane, relay, combined mode, and connect | Bearer token. Wins over the token file. Loses to `--token`. |
| `AGENTLINK_PLANE` | `agentlink connect` | Plane WebSocket URL. A URL with no path uses `/acp`. |
| `AGENTLINK_TARGET` | `agentlink connect` | Agent name. Compared as given, after trimming. |
| `AGENTLINK_WINDOWS_START` | The CLI, on Windows | Set to `1` by `bin/agentlink.bat start`. One leading `start` is then dropped. The agent process does not inherit this variable. |
| `RELEASE_DISTRIBUTION` | The release script | Default `none` from `rel/env.sh.eex`. `sname` is required for `stop`, `remote`, `rpc`, and `pid`. |
| `RELEASE_NODE` | The release script | Erlang node name. Required when distribution is not `none`. Must differ for each release on one machine. |
| `RELEASE_ROOT` | The CLI | When set, arguments are the release boot arguments, and the words after the first bare `--` are kept. |
| `RELEASE_TMP` | The reaper | Reaper record directory when `:reaper_dir` is unset. When this variable is also unset, the directory is `$HOME/.agentlink/run`. |
| `AGENTLINK_WEBSOCKET_PING_INTERVAL` | Uplink and `agentlink connect` | Ping interval in milliseconds. Read when the dial process starts. [Keepalive](#keepalive) has the accepted values. |
| `AGENTLINK_WEBSOCKET_PONG_TIMEOUT` | Uplink and `agentlink connect` | Pong timeout in milliseconds. Read when the dial process starts. [Keepalive](#keepalive) has the accepted values. |

`AGENTLINK_BIN` and `OPENCODE_BIN` are read by the test suite, not by a running `agentlink` process. [Contributing](../../CONTRIBUTING.md) has the commands.

The dial timeout is 3000 milliseconds. The retry wait defaults to 500 milliseconds, and a shorter backoff is raised to 50. Neither value is an environment variable. The plane idle timeout is infinity. [Reconnect and keepalive](../explanation/reconnect.md) describes those timers and the ping.

The agent process receives the VM environment without `AGENTLINK_WINDOWS_START`. The link file cannot set variables. An `env` key is an error.

## Config file

The path is `$HOME/.agentlink/config`. The file is JSON. `plane` and `target` are optional strings. A missing key and a null value are unset. Any other key is ignored, except `token`.

A `token` key is an error. The message is `<path> must not contain a token. Put the token in <token path>.` A missing file leaves `plane` and `target` unset. A file that is not a JSON object is an error. The message is `<path> is not a JSON object.` A `plane` or `target` value that is not a string is an error. The message is `<path> <key> must be a string.`

## Token file

The path is `$HOME/.agentlink/token`. It is read only when the token is still unset. The file must be a regular file. The permission bits must be `0600`, `0400`, `0200`, or `0000`. Any other bit is rejected. The message names the path, prints the mode, and says it must be `0600` or tighter. A missing file leaves the token unset. The body must be valid UTF-8. It is trimmed.

## Application environment

`config/config.exs` compiles these defaults. There is no `config/runtime.exs`.

| Key | Default |
| --- | --- |
| `:port` | `8090` |
| `:mode` | `:all` |
| `:plane_url` | `ws://127.0.0.1:8090/agent` |
| `:master_token` | `nil` until startup resolves a token |
| `:agent_module` | `AgentLink.Agent.Process` |
| `:access` | `AgentLink.Access.Single` |
| `:cli` | `true` |
| `:agent_stop_timeout` | `5000` milliseconds |
| `:websocket_ping_interval` | `30000` milliseconds |
| `:websocket_pong_timeout` | `10000` milliseconds |

A non-empty argument list replaces `:mode` and, when the flags are present, `:port`, `:cli_token`, and `:link_path`. `--link` sets `:link_path`. The default link path is `$HOME/.agentlink/agent.link.json`.

`:workdir` overrides the agent workspace. The default is `$HOME/.agentlink/workspace`. There is no command-line flag for it.

`:reaper_dir` overrides the reaper directory. There is no command-line flag for it. [Agent process](../agent.md#reaper) describes the file.

`:config_root` replaces `$HOME/.agentlink` for the config and token lookup. `:config_env` replaces the environment map passed to that lookup. Neither has a command-line flag.

## Keepalive

The uplink and `agentlink connect` read the ping interval and the pong timeout when the dial process starts. There is no command-line flag. The first accepted source wins.

| Source | Ping interval | Pong timeout |
| --- | --- | --- |
| Start option on `AgentLink.Transport.WebSocket.start_link/1` | `:ping_interval` | `:pong_timeout` |
| Environment variable | `AGENTLINK_WEBSOCKET_PING_INTERVAL` | `AGENTLINK_WEBSOCKET_PONG_TIMEOUT` |
| `:agent_link` application env | `:websocket_ping_interval` | `:websocket_pong_timeout` |
| Built-in default | `30000` | `10000` |

A positive integer is greater than 0 and at most 4294967295. A string is accepted when the trimmed text parses as one integer in that range and contains nothing else. A missing variable, a nil, and a blank string are skipped, and they are not logged. Any other value is logged and then skipped. The warning starts with `transport keepalive`, then the source name, then `ignored`. A binary longer than 64 bytes keeps the first 64 bytes and then `...`.

The agent relay forwards `:transport_opts` to the uplink. A caller inside the VM can set `:ping_interval` and `:pong_timeout` there. `agentlink connect` does not forward those options. Both processes still read the environment variables and the application env.

`config/test.exs` sets both application keys to 3600000. That keeps the timer from firing during a test. A test that covers the timer passes a start option or sets the variable itself.

On Linux the dial sets `TCP_USER_TIMEOUT` to the interval plus the pong timeout, and not above 2147483647. Other operating systems leave the option unset. The dial does not enable `SO_KEEPALIVE`. [Set the keepalive](../how-to/set-the-keepalive.md) is the procedure. [Reconnect and keepalive](../explanation/reconnect.md) explains the ping timer and `TCP_USER_TIMEOUT`.
