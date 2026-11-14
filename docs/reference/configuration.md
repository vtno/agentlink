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

`AGENTLINK_BIN` and `OPENCODE_BIN` are read by the test suite, not by a running `agentlink` process. [Contributing](../../CONTRIBUTING.md) has the commands.

AgentLink does not read `AGENTLINK_WEBSOCKET_PING_INTERVAL`. AgentLink does not read `AGENTLINK_WEBSOCKET_PONG_TIMEOUT`. Dial retry, the connect timeout, and the idle timeout are fixed in code. [Reconnect and keepalive](../explanation/reconnect.md) states those values.

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

A non-empty argument list replaces `:mode` and, when the flags are present, `:port`, `:cli_token`, and `:link_path`. `--link` sets `:link_path`. The default link path is `$HOME/.agentlink/agent.link.json`.

`:workdir` overrides the agent workspace. The default is `$HOME/.agentlink/workspace`. There is no command-line flag for it.

`:reaper_dir` overrides the reaper directory. There is no command-line flag for it. [Agent process](../agent.md#reaper) describes the file.

`:config_root` replaces `$HOME/.agentlink` for the config and token lookup. `:config_env` replaces the environment map passed to that lookup. Neither has a command-line flag.
