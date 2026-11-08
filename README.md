# AgentLink

Agent and editor vendors each build their own walled garden to keep you on their platform. AgentLink is a neutral bridge. It proxies [Agent Client Protocol](https://agentclientprotocol.com) (ACP) messages between editors and agents, so you choose the agent and the editor separately. You keep the agent on your own machine and reach it from wherever you can reach the plane. The link file names the command. For OpenCode, set `command` to `opencode` and `args` to `["acp"]`. Another installed adapter uses the same fields, for example `kimi` and `["acp"]`. More agents are described in [Add Claude Code and Codex agents](https://github.com/vtno/agentlink/issues/10).

A client is a program connected to the plane.

The plane accepts client connections. The relay opens one agent and starts an uplink. The uplink dials the plane. One plane keeps one live uplink for each link name.

ACP messages are JSON-RPC. The agent writes one JSON object per line on its standard output. The uplink sends one JSON object in each WebSocket text frame.

## Run AgentLink from source

You need Elixir 1.17 or a later 1.x release. To run an agent, the `command` in the link file must name an executable `AgentLink.Agent.Process` can open. A bare name is resolved with `System.find_executable/1`. An absolute path is used as written.

`agentlink plane` does not read the link file. `agentlink connect` does not read the link file. A relay exits when the file is missing. The error begins `No link file at`. AgentLink prints the startup lines before it reads the link file. Those lines include the token. When the file is missing, AgentLink then prints the error and exits.

Create `$HOME/.agentlink/agent.link.json` with the object below when you start a relay.

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

`program` is metadata. It does not select `command`. When `program` is missing, `AgentLink.Link` uses `opencode`. `command` and `args` are required. `args` may be `[]`.

See [Link file](#link-file) for the field rules.

1. Save that object as `$HOME/.agentlink/agent.link.json`.
2. Run `mix deps.get`.
3. Run `mix run --no-halt`.
4. Confirm that the log contains `opened AgentLink.Agent.Process`.

`mix run --no-halt` starts the plane and the relay. Pass AgentLink flags after `--`.

```sh
mix run --no-halt -- --port 8090 --token 'the-token'
mix run --no-halt -- plane --port 8090
mix run --no-halt -- relay --token 'the-token'
mix run --no-halt -- connect --plane ws://127.0.0.1:8090/acp --token 'the-token'
```

`plane` starts the plane alone. `relay` starts the relay alone. `connect` starts the client relay alone. See [Command line](#command-line) for the flags.

A plane with no token creates one for that process and prints it. Look for `AgentLink created a token for this process. Pass the same --token to start again.` AgentLink also prints `agentlink relay --token '…'`. AgentLink does not write the token to disk. Pass the same `--token` the next time you start the plane.

## Build a binary

The build machine needs Elixir 1.17 or a later 1.x release, Zig 0.16.0, and `xz` on `PATH`. Burrito exits with status 1 when the Zig version is not 0.16.0. Burrito also exits with status 1 when `zig` or `xz` is missing. A Windows build needs `7z` or `7zz` on `PATH`. When `7z` and `7zz` are both missing, Burrito warns that Windows releases fail. The machine that runs the binary does not need Elixir.

1. Run `mix deps.get`.
2. Run `MIX_ENV=prod mix release`.
3. Put the binary for your machine on `PATH` as `agentlink`.

With no `BURRITO_TARGET`, step 2 writes three binaries.

- `burrito_out/agentlink_linux` is the Linux x86_64 binary.
- `burrito_out/agentlink_macos` is the macOS binary for Apple Silicon (aarch64).
- `burrito_out/agentlink_windows.exe` is the Windows x86_64 binary.

Burrito prints `Output Path:` and the file it wrote.

To build one binary, set `BURRITO_TARGET` to `linux`, `macos`, or `windows`.

```sh
agentlink
agentlink plane --port 8090
agentlink relay --token 'the-token'
agentlink connect --plane ws://127.0.0.1:8090/acp --token 'the-token'
```

## Reach a plane on another machine

The plane listens only on `127.0.0.1` over plain `ws://`, and AgentLink does not terminate TLS. Choose one way below to reach the plane from another machine.

- Use an ssh tunnel when you reach one machine and you want no extra software. `plane_url` is `ws://127.0.0.1`.
- Use Tailscale serve when the plane and the relay are already on a tailnet. `plane_url` is `wss://`.
- Use Caddy or another TLS reverse proxy when you have a public domain and ports 80 and 443 are reachable. `plane_url` is `wss://`.

The examples use the default port, 8090. If you set `--port`, use that port in the example and in `plane_url`. The path in each `plane_url` is `/agent`. The uplink dials TLS for a `wss://` plane URL. Mint verifies the server certificate against the system CA store.

### Option 1: ssh tunnel

Open the tunnel on the relay's machine. `host` is the machine that runs the plane.

```sh
ssh -L 8090:127.0.0.1:8090 host
```

Set `plane_url` to `ws://127.0.0.1:8090/agent`.

### Option 2: Tailscale serve

Run this command on the plane's machine.

```sh
tailscale serve --https=443 http://127.0.0.1:8090
```

Set `plane_url` to a `wss://` URL whose host is the Tailscale host and whose path is `/agent`.

### Option 3: Caddy or another TLS reverse proxy

Run Caddy on the plane's machine. Caddy obtains the certificate and proxies the WebSocket upgrade.

```
plane.example.com {
	reverse_proxy 127.0.0.1:8090
}
```

Set `plane_url` to `wss://plane.example.com/agent`.

Another TLS reverse proxy uses the same shape. Forward to `127.0.0.1:8090`, and set `plane_url` to that proxy's `wss://` URL with path `/agent`.

Do not publish the plane's listen port. A proxy can log the `?token=` query string. Turn query logging off before you proxy the plane. See [Security model](#security-model) for why the listen port stays on localhost.

## Security model

AgentLink ships with one operator and one token. `AgentLink.Access.Single` is that policy. `--token` sets the token. When a plane starts with no token, AgentLink creates one for that process and prints it. AgentLink does not write the token to disk. The next start needs the same `--token`. The subject for that token is an admin. The admin may use every uplink.

A caller presents the token in the `Authorization` header or in `?token=`. The header scheme is `Bearer` or `bearer`. When `?token=` is present and not empty, AgentLink uses that value and does not read the header. The uplink sends the header. The uplink does not put the token in `plane_url`.

The listener is plain `ws://` on `127.0.0.1`. The token identifies the caller. The token does not encrypt the WebSocket. A relay on another machine reaches the plane through an ssh tunnel or a TLS proxy. See [Reach a plane on another machine](#reach-a-plane-on-another-machine). The plane's listen port stays on localhost. A proxy can store `?token=` in its logs.

`GET /health` does not read the token. `GET /acp`, `GET /agent`, and `GET /status` require the token. See [HTTP routes](#http-routes) for those paths.

`AgentLink.Access` is the extension point. Set the `:access` application env to another module to replace `AgentLink.Access.Single`. That module implements `authenticate/1`, `allowed?/2`, and `prepare/1`. `claim/2` is optional. `:reject` from `claim/2` closes the uplink with code 4004. See [Uplink close codes](#uplink-close-codes).

## Reference

### Command line

```
agentlink [--port PORT] [--token TOKEN]
agentlink plane [--port PORT] [--token TOKEN]
agentlink relay --token TOKEN
agentlink connect [--plane URL] [--target NAME] [--token TOKEN]
```

`agentlink` with no arguments starts the plane and the relay.

`--port` is an integer from 1 to 65535. The default is 8090. `agentlink relay` rejects `--port` and prints `agentlink relay does not listen.`

`--token` is the token. `agentlink relay` requires `--token`. Without it, AgentLink prints `agentlink relay needs --token.` A plane with no token creates one. See [Security model](#security-model).

`--opencode-bin` is rejected. The usage text does not list it. The command and the args come from the link file.

`agentlink connect` starts the client relay. The editor runs that command as its ACP agent over stdio. The command does not start the plane or the agent relay, and it does not read the link file.

`--plane` is the plane WebSocket URL. `--target` is the agent name. `--token` is the bearer token. For each value, a flag that has text wins over the environment variable, and an environment variable that has text wins over the file. A blank value is unset. The variables are `AGENTLINK_PLANE`, `AGENTLINK_TARGET`, and `AGENTLINK_TOKEN`. The config file is `$HOME/.agentlink/config`, a JSON object with `plane` and an optional `target`. The token file is `$HOME/.agentlink/token`. Its mode is 0600 or tighter. A `token` key in the config file is an error.

A URL with no path uses `/acp`. When the plane URL is missing, the error begins `agentlink connect needs a plane URL.` The command exits with status 1. When the token is missing, the error begins `agentlink connect needs a token.` The command exits with status 1. When no single online agent can be selected, the client relay stops and the command exits with status 1. The client relay's message lists the online agents. When none are online, the message says that no agent is online. When stdin closes, including when it is already closed as the client relay starts, the command exits with status 0.

`--help` and `-h` print the usage and exit with status 0. A bad command exits with status 1.

The listener binds only `127.0.0.1`. The scheme is HTTP, so the plane's own URL is `ws://`.

### HTTP routes

The plane serves these GET routes on the listen port. The default port is 8090.

| Request | Result |
|---|---|
| `GET /health` | Status 200. The body is `ok`. AgentLink does not read the token. |
| `GET /status` | Status 200. The body is JSON. AgentLink requires the token. |
| `GET /acp` | WebSocket for a client. AgentLink requires the token. |
| `GET /agent` | WebSocket the uplink dials. AgentLink requires the token. |

The plane returns status 401 and the body `unauthorized` when it rejects the token. The plane returns status 404 and the body `not found` for any other path.

`GET /status` uses content type `application/json`. The object has two keys.

- `plane` is the text `127.0.0.1:` followed by the listen port.
- `runtimes` is the list `AgentLink.Access` allows for this caller. Each entry has `name`, `label`, `program`, and `connected_at`. `connected_at` is seconds since 1970-01-01 00:00:00 UTC.

### Link file

`AgentLink.Link` reads `$HOME/.agentlink/agent.link.json`. The relay starts when that file exists, is a JSON object, and includes `command` and `args`. `agentlink plane` does not read the file.

When the file is present and only `command` or `args` change, the running child and the current uplink stay as they are. The next start of the relay reads the new `command` and `args`. An automatic restart is one of those starts.

When the file is missing, the uplink stops. The relay supervisor starts the relay again. That start fails because the file is missing. The supervisor stops after 5 restarts in 20 seconds. A start that cannot open the `command` counts toward those 5 restarts. In `all` mode the relay supervisor is transient, so the plane keeps running. In `relay` mode `AgentLink.Relay.Agent` is a child of the application supervisor. When that supervisor stops, the node stops.

The object holds `name`, `label`, `program`, `plane_url`, `command`, and `args`. `AgentLink.Link` keeps `name`, `label`, `program`, and `plane_url`. `AgentLink.Agent.Launch` keeps `command` and `args`.

`AgentLink.Link` turns `name` into a slug before the uplink dials. Letters become lowercase. Each run of characters other than letters and digits becomes one `-`. The slug then removes dashes at the ends and keeps at most 40 characters. `Lab Box` becomes `lab-box`.

`AgentLink.Link` chooses `label` first. When `label` is missing and `name` is present, `AgentLink.Link` uses `name`. When `name` and `label` are both missing, `label` is `this machine`. The slug comes from `name` when that field is present. Otherwise the slug comes from `label`. `AgentLink.Link` uses `opencode` when the slug is empty. With both fields missing, `name` is `this-machine`.

When `program` is missing, `AgentLink.Link` uses `opencode`. When `plane_url` is missing, `AgentLink.Link` uses `ws://127.0.0.1:8090/agent`.

On hello, AgentLink stores at most 80 characters of `label` and at most 80 characters of `program`.

The plane accepts a hello name of 1 to 40 characters that matches `^[a-z0-9][a-z0-9_-]{0,39}$`. The plane closes any other name with code 4003.

`plane_url` chooses the scheme, the host, the port, and the path. `wss` and `https` use TLS. The default port for those schemes is 443. `ws` and `http` stay plain. The default port for those schemes is 80. When the path is missing, the uplink uses `/agent`. When the host is missing, the uplink dials `127.0.0.1`. The uplink ignores the query string. For `wss` and `https`, Mint verifies the server certificate against the system CA store from `:public_key.cacerts_get/0`.

`label` is the display name. `program` is metadata, such as `opencode`. It does not select `command`. When `program` is missing, `AgentLink.Link` uses `opencode`.

`command` is a bare name or an absolute path. `AgentLink.Agent.Launch.load/1` trims it. `args` is a list of strings. `[]` is valid. Each string is kept as written. An `env` key is an error. OpenCode uses `"command": "opencode"` and `"args": ["acp"]`. `kimi` with `["acp"]` is the same shape. AgentLink does not add `acp`, and it does not set `OPENCODE_DISABLE_AUTOUPDATE`.

### Uplink close codes

The uplink hello is a JSON-RPC request with method `agentlink.uplink`. The params are `name`, `label`, `program`, and `instance`.

`instance` identifies this OS process. A new uplink process in the same VM keeps the same id. A second OS process has a new id. The same id means the same relay. The plane accepts an id of at most 128 bytes.

The first hello for a name keeps the socket. The same relay can dial again after a label change, a program change, or a dropped socket. The plane releases the previous socket and keeps the new one. The plane then drops that name's session state. The plane fails in-flight requests with JSON-RPC error -32000 and the message `runtime reconnected`.

The plane closes a hello from a different relay with code 4001 while the current relay is connected. When the current relay disconnects, the plane frees the name. The plane fails those in-flight requests with JSON-RPC error -32000 and the message `runtime disconnected`.

`AgentLink.AgentSocketProtocol` defines the close codes. A parked uplink does not dial again on its own. The last column says when a new dial happens.

| Code | Reason | When the uplink dials again |
|---|---|---|
| 4001 | `name "<name>" is in use; stop the other relay or change name` | After a change to `name` or to `plane_url`, or after a restart |
| 4002 | `instance id is too long; max is 128 bytes` | After a restart |
| 4003 | `link name must be a short slug` | After a change to `name` or to `plane_url`, or after a restart |
| 4004 | `uplink is not allowed` | After a change to `name` or to `plane_url`, or after a restart |

When `name` is not a string, code 4001 uses the reason `name is in use; stop the other relay or change name`.

A change to `label` or `program` does not let a parked uplink dial again when the code is 4001, 4003, or 4004. For code 4002, the uplink still does not dial again when `name` or `plane_url` changes. The id is not in the link file.

Code 4004 means `AgentLink.Access` rejected the hello. The uplink dials again on restart after the policy allows that uplink. A change to `name` or to `plane_url` makes the uplink dial again.

Any other close retries after 500 milliseconds. A failed dial does the same.

### Client socket

A client connects to `ws://127.0.0.1:8090/acp`. The client sends the token as `Authorization: Bearer` or as `?token=`.

`runtime/list` returns the runtimes this caller may use. `runtime/select` with `params.name` binds the client to that runtime. The errors are `runtime name is required`, `runtime is not connected`, and `runtime is not allowed`.

Other ACP methods need a selected runtime. When the caller may use exactly one connected runtime, the plane selects that runtime. Otherwise the plane reports one of these errors.

- The error is `no runtime connected` when no runtime is connected.
- The error is `runtime is not allowed` when runtimes are connected and this caller may use none of them.
- The error is `select a runtime` when the caller may use several.

The client sends ACP requests. The methods include `initialize`, `session/new`, `session/load`, and `session/prompt`.

The plane forwards only the first `initialize` for a runtime. An `initialize` that arrives before the agent answers waits for that result. After the agent answers, a later `initialize` on that runtime receives the cached result. Each client keeps the `clientCapabilities` from its own `initialize`. The agent sees only the capabilities from the first `initialize`.

The agent runs one `session/prompt` at a time. An agent request goes to the client that has the matching `session/prompt` in flight. The plane applies the capability rules below to that client. When no client matches, the plane answers the agent with JSON-RPC error -32000. The message is `no app is attached to this session`. When more than one client matches, the plane sends that same error.

The plane forwards an agent file or terminal request for that client only in the cases below.

- The plane forwards `fs/read_text_file` when that client's `fs.readTextFile` is true.
- The plane forwards `fs/write_text_file` when that client's `fs.writeTextFile` is true.
- The plane forwards a method whose name starts with `terminal/` when that client's `terminal` is true.

The plane does not forward any other method whose name starts with `fs/` or `terminal/`. Those refusals use JSON-RPC error -32601 and the message `client does not support this method`.

The plane sends a live `session/update` with a binary `sessionId` and a map `update` to each client that has that session open. It calls `AgentLink.Plane.Sessions.broadcast/3`. A `session/update` with a binary `sessionId` whose `update` is not a map is dropped. The plane logs a warning and does not store that update. A client opens a session with `session/new`, `session/load`, or `session/resume`. `session/close` drops that client from that session. The session stays in the directory, so a later `session/load` still replays the stored updates. The plane sends a `session/update` with no `sessionId` to every client on that runtime.

The plane answers `session/list` from the directory and does not forward it. A bad cursor is JSON-RPC error -32602 and the message `invalid cursor`. For a known session, the plane sends the replay and then answers `session/load` with an empty result. It does not forward `session/load`. An unknown session is JSON-RPC error -32002 and the message `session not found`. `session/resume` joins a known session and does not replay. `session/close` answers an empty result. A second `session/close` for that session answers an empty result again. The plane does not forward `session/close`.

The plane answers a non-JSON text frame with JSON-RPC error -32700 and the message `parse error`.

For `session/new` and `session/load`, the relay replaces a missing, null, or empty-string `cwd` with the workspace before the write to the agent. The relay leaves any other `cwd` unchanged. That path is on the agent's machine.

### Agent process

The default workspace is `$HOME/.agentlink/workspace`. The relay creates that directory.

`AgentLink.Agent.Process` runs `command` and `args` in that workspace. The child inherits the VM environment. Stderr stays off the ACP stream. `close/1` closes the port, which closes the child's stdin. `close/1` does not reap a process tree.

The relay reads one JSON object per line from the agent's standard output. The relay writes one JSON object and a newline to the agent's standard input.

## Run the tests

`mix test` does not start a provider. `mix test` excludes tests tagged `:wrapped`.

Set `AGENTLINK_BIN` to the wrapped binary. When `opencode` is not on `PATH`, also set `OPENCODE_BIN`.

```sh
AGENTLINK_BIN=./burrito_out/agentlink_linux OPENCODE_BIN=/path/to/opencode mix test --only wrapped
```

The wrapped test starts the binary. The test asks OpenCode to write an HTML page, then checks the page.
