# Pont

Agent and editor vendors each build their own walled garden to keep you on their platform. Pont is a neutral bridge. It proxies [Agent Client Protocol](https://agentclientprotocol.com) (ACP) messages between editors and agents, so you choose the agent and the editor separately. You keep the agent on your own machine and reach it from wherever you can reach the plane. Pont runs OpenCode today, and more agents are planned in [issue #10](https://github.com/vtno/pont/issues/10).

A client is a program connected to the plane.

The plane accepts client connections. The relay opens one agent and starts an uplink. The uplink dials the plane. One plane keeps one live uplink for each link name.

ACP messages are JSON-RPC. The agent writes one JSON object per line on its standard output. The uplink sends one JSON object in each WebSocket text frame.

## Run Pont from source

You need Elixir 1.17 or a later 1.x release. To run an agent, you also need the `opencode` binary. Pont looks for `opencode` on `PATH`, then at `$HOME/.local/bin/opencode`.

`pont plane` does not read the link file. A relay exits when the file is missing. The error begins `No link file at`. Pont prints the startup lines before it reads the link file. Those lines include the token. When the file is missing, Pont then prints the error and exits.

Create `$HOME/.pont/agent.link.json` with the object below when you start a relay.

```json
{
  "name": "opencode",
  "label": "this machine",
  "program": "opencode",
  "plane_url": "ws://127.0.0.1:8090/agent"
}
```

See [Link file](#link-file) for the field rules.

1. Save that object as `$HOME/.pont/agent.link.json`.
2. Run `mix deps.get`.
3. Run `mix run --no-halt`.
4. Confirm that the log contains `opened Pont.OpenCode`.

`mix run --no-halt` starts the plane and the relay. Pass Pont flags after `--`.

```sh
mix run --no-halt -- --port 8090 --token 'the-token'
mix run --no-halt -- plane --port 8090
mix run --no-halt -- relay --token 'the-token' --opencode-bin /usr/local/bin/opencode
```

`plane` starts the plane alone. `relay` starts the relay alone. See [Command line](#command-line) for the flags.

A plane with no token creates one for that process and prints it. Look for `Pont created a token for this process. Pass the same --token to start again.` Pont also prints `pont relay --token '…'`. Pont does not write the token to disk. Pass the same `--token` the next time you start the plane.

## Build a binary

The build machine needs Elixir 1.17 or a later 1.x release, Zig 0.16.0, and `xz` on `PATH`. Burrito exits with status 1 when the Zig version is not 0.16.0. Burrito also exits with status 1 when `zig` or `xz` is missing. A Windows build needs `7z` or `7zz` on `PATH`. When `7z` and `7zz` are both missing, Burrito warns that Windows releases fail. The machine that runs the binary does not need Elixir.

1. Run `mix deps.get`.
2. Run `MIX_ENV=prod mix release`.
3. Put the binary for your machine on `PATH` as `pont`.

With no `BURRITO_TARGET`, step 2 writes three binaries.

- `burrito_out/pont_linux` is the Linux x86_64 binary.
- `burrito_out/pont_macos` is the macOS binary for Apple Silicon (aarch64).
- `burrito_out/pont_windows.exe` is the Windows x86_64 binary.

Burrito prints `Output Path:` and the file it wrote.

To build one binary, set `BURRITO_TARGET` to `linux`, `macos`, or `windows`.

```sh
pont
pont plane --port 8090
pont relay --token 'the-token'
```

## Reach a plane on another machine

The plane listens on `127.0.0.1` with plain `ws://`. Pont does not terminate TLS.

Do not publish the plane's listen port. A proxy can log the `?token=` query string. Turn query logging off before you proxy the plane.

To dial the plane from another machine, run a TLS proxy on the plane's machine. Set `plane_url` to that `wss://` URL. The path is `/agent`. The uplink dials `wss` with TLS. Mint verifies the server certificate against the system CA store. See [Security model](#security-model) for the reason the listen port stays on localhost.

The examples below use the default port, 8090. If you set `--port`, use that port in the proxy and in `plane_url`.

To use Caddy, run it on the plane's machine. Caddy obtains the certificate and proxies the WebSocket upgrade.

```
plane.example.com {
	reverse_proxy 127.0.0.1:8090
}
```

Set `plane_url` to `wss://plane.example.com/agent`.

To use Tailscale, run the command below on the plane's machine.

```sh
tailscale serve --https=443 http://127.0.0.1:8090
```

Set `plane_url` to a `wss://` URL whose host is the Tailscale host and whose path is `/agent`.

To keep plain `ws://` on the relay's machine, open a tunnel there. `host` is the machine that runs the plane.

```sh
ssh -L 8090:127.0.0.1:8090 host
```

Set `plane_url` to `ws://127.0.0.1:8090/agent`.

## Security model

Pont ships with one operator and one token. `Pont.Access.Single` is that policy. `--token` sets the token. When a plane starts with no token, Pont creates one for that process and prints it. Pont does not write the token to disk. The next start needs the same `--token`. The subject for that token is an admin. The admin may use every uplink.

A caller presents the token in the `Authorization` header or in `?token=`. The header scheme is `Bearer` or `bearer`. When `?token=` is present and not empty, Pont uses that value and does not read the header. The uplink sends the header. The uplink does not put the token in `plane_url`.

The listener is plain `ws://` on `127.0.0.1`. The token identifies the caller. The token does not encrypt the WebSocket. A relay on another machine reaches the plane through a TLS proxy. See [Reach a plane on another machine](#reach-a-plane-on-another-machine). The plane's listen port stays on localhost. A proxy can store `?token=` in its logs.

`GET /health` does not read the token. `GET /acp`, `GET /agent`, and `GET /status` require the token. See [HTTP routes](#http-routes) for those paths.

`Pont.Access` is the extension point. Set the `:access` application env to another module to replace `Pont.Access.Single`. That module implements `authenticate/1`, `allowed?/2`, and `prepare/1`. `claim/2` is optional. `:reject` from `claim/2` closes the uplink with code 4004. See [Uplink close codes](#uplink-close-codes).

## Reference

### Command line

```
pont [--port PORT] [--token TOKEN] [--opencode-bin PATH]
pont plane [--port PORT] [--token TOKEN]
pont relay --token TOKEN [--opencode-bin PATH]
```

`pont` with no arguments starts the plane and the relay.

`--port` is an integer from 1 to 65535. The default is 8090. `pont relay` rejects `--port` and prints `pont relay does not listen.`

`--token` is the token. `pont relay` requires `--token`. Without it, Pont prints `pont relay needs --token.` A plane with no token creates one. See [Security model](#security-model).

`--opencode-bin` is the OpenCode executable. Pont rejects the flag when that file does not exist. `pont plane` rejects the flag and prints `pont plane does not run opencode.`

`--help` and `-h` print the usage and exit with status 0. A bad command exits with status 1.

The listener binds only `127.0.0.1`. The scheme is HTTP, so the plane's own URL is `ws://`.

### HTTP routes

The plane serves these GET routes on the listen port. The default port is 8090.

| Request | Result |
|---|---|
| `GET /health` | Status 200. The body is `ok`. Pont does not read the token. |
| `GET /status` | Status 200. The body is JSON. Pont requires the token. |
| `GET /acp` | WebSocket for a client. Pont requires the token. |
| `GET /agent` | WebSocket the uplink dials. Pont requires the token. |

The plane returns status 401 and the body `unauthorized` when it rejects the token. The plane returns status 404 and the body `not found` for any other path.

`GET /status` uses content type `application/json`. The object has two keys.

- `plane` is the text `127.0.0.1:` followed by the listen port.
- `runtimes` is the list `Pont.Access` allows for this caller. Each entry has `name`, `label`, `program`, and `connected_at`. `connected_at` is seconds since 1970-01-01 00:00:00 UTC.

### Link file

`Pont.Link` reads `$HOME/.pont/agent.link.json`. The relay does not start until that file exists and is a JSON object. `pont plane` does not read the file.

If the file is deleted after startup, the uplink stops. The relay supervisor restarts the relay. The relay supervisor stops after 5 restarts in 20 seconds. A plane started beside the relay keeps running.

The object holds `name`, `label`, `program`, and `plane_url`.

`Pont.Link` turns `name` into a slug before the uplink dials. Letters become lowercase. Each run of characters other than letters and digits becomes one `-`. The slug then removes dashes at the ends and keeps at most 40 characters. `Lab Box` becomes `lab-box`.

`Pont.Link` chooses `label` first. When `label` is missing and `name` is present, `Pont.Link` uses `name`. When `name` and `label` are both missing, `label` is `this machine`. The slug comes from `name` when that field is present. Otherwise the slug comes from `label`. `Pont.Link` uses `opencode` when the slug is empty. With both fields missing, `name` is `this-machine`.

When `program` is missing, `Pont.Link` uses `opencode`. When `plane_url` is missing, `Pont.Link` uses `ws://127.0.0.1:8090/agent`.

On hello, Pont stores at most 80 characters of `label` and at most 80 characters of `program`.

The plane accepts a hello name of 1 to 40 characters that matches `^[a-z0-9][a-z0-9_-]{0,39}$`. The plane closes any other name with code 4003.

`plane_url` chooses the scheme, the host, the port, and the path. `wss` and `https` use TLS. The default port for those schemes is 443. `ws` and `http` stay plain. The default port for those schemes is 80. When the path is missing, the uplink uses `/agent`. When the host is missing, the uplink dials `127.0.0.1`. The uplink ignores the query string. For `wss` and `https`, Mint verifies the server certificate against the system CA store from `:public_key.cacerts_get/0`.

`label` is the display name. `program` is the product name, such as `opencode`.

### Uplink close codes

The uplink hello is a JSON-RPC request with method `pont.uplink`. The params are `name`, `label`, `program`, and `instance`.

`instance` identifies this OS process. A new uplink process in the same VM keeps the same id. A second OS process has a new id. The same id means the same relay. The plane accepts an id of at most 128 bytes.

The first hello for a name keeps the socket. The same relay can dial again after a label change, a program change, or a dropped socket. The plane releases the previous socket and keeps the new one. The plane then drops that name's session state. The plane fails in-flight requests with JSON-RPC error -32000 and the message `runtime reconnected`.

The plane closes a hello from a different relay with code 4001 while the current relay is connected. When the current relay disconnects, the plane frees the name. The plane fails those in-flight requests with JSON-RPC error -32000 and the message `runtime disconnected`.

`Pont.AgentSocketProtocol` defines the close codes. A parked uplink does not dial again on its own. The last column says when a new dial happens.

| Code | Reason | When the uplink dials again |
|---|---|---|
| 4001 | `name "<name>" is in use; stop the other relay or change name` | After a change to `name` or to `plane_url`, or after a restart |
| 4002 | `instance id is too long; max is 128 bytes` | After a restart |
| 4003 | `link name must be a short slug` | After a change to `name` or to `plane_url`, or after a restart |
| 4004 | `uplink is not allowed` | After a change to `name` or to `plane_url`, or after a restart |

When `name` is not a string, code 4001 uses the reason `name is in use; stop the other relay or change name`.

A change to `label` or `program` does not let a parked uplink dial again when the code is 4001, 4003, or 4004. For code 4002, the uplink still does not dial again when `name` or `plane_url` changes. The id is not in the link file.

Code 4004 means `Pont.Access` rejected the hello. The uplink dials again on restart after the policy allows that uplink. A change to `name` or to `plane_url` makes the uplink dial again.

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

The agent runs one `session/prompt` at a time. An agent request goes to the client that has the matching `session/prompt` or `session/load` in flight. The plane applies the capability rules below to that client. When no client matches, the plane answers the agent with JSON-RPC error -32000. The message is `no app is attached to this session`. When more than one client matches, the plane sends that same error.

The plane forwards an agent file or terminal request for that client only in the cases below.

- The plane forwards `fs/read_text_file` when that client's `fs.readTextFile` is true.
- The plane forwards `fs/write_text_file` when that client's `fs.writeTextFile` is true.
- The plane forwards a method whose name starts with `terminal/` when that client's `terminal` is true.

The plane does not forward any other method whose name starts with `fs/` or `terminal/`. Those refusals use JSON-RPC error -32601 and the message `client does not support this method`.

The plane sends an agent notification that carries a `sessionId` to the clients on that runtime with that `sessionId`. During `session/load` for that session, the client whose `session/load` is in flight receives the notification instead. The plane sends an agent notification with no `sessionId` to every client on that runtime.

The plane answers a non-JSON text frame with JSON-RPC error -32700 and the message `parse error`.

For `session/new` and `session/load`, the relay replaces a missing, null, or empty-string `cwd` with the workspace before the write to the agent. The relay leaves any other `cwd` unchanged. That path is on the agent's machine.

### Agent process

The default workspace is `$HOME/.pont/workspace`. The relay creates that directory.

`Pont.OpenCode` runs `opencode acp` in that workspace. `Pont.OpenCode` leaves stderr off the ACP stream. The process environment includes `OPENCODE_DISABLE_AUTOUPDATE=1`.

The relay reads one JSON object per line from the agent's standard output. The relay writes one JSON object and a newline to the agent's standard input.

## Run the tests

`mix test` does not start OpenCode. `mix test` excludes tests tagged `:wrapped`.

Set `PONT_BIN` to the wrapped binary. When `opencode` is not on `PATH`, also set `OPENCODE_BIN`.

```sh
PONT_BIN=./burrito_out/pont_linux OPENCODE_BIN=/path/to/opencode mix test --only wrapped
```

The wrapped test starts the binary. The test asks OpenCode to write an HTML page, then checks the page.
