# Link file

`AgentLink.Link` reads `$HOME/.agentlink/agent.link.json` unless `agentlink relay --link` set another path. `agentlink plane` and `agentlink connect` do not read the file. The relay starts when the file exists, is a JSON object, and includes `command` and `args`.

`name`, `label`, `program`, and `plane_url` become the link. `command` and `args` become the launch. They are not fields of the link. Any other unknown key is ignored. An `env` key is an error, including when the value is null. The message is `<path> must not contain env.` The value is not included. `env` is checked before `command` and `args`.

## Fields

| Field | Required | When it is missing |
| --- | --- | --- |
| `command` | Yes | The start fails. The message is `<path> must include a command.` |
| `args` | Yes | The start fails. The message is `<path> must include args.` |
| `name` | No | The slug is taken from `label`. |
| `label` | No | `name` is used when it is present. Otherwise the label is `this machine`. |
| `program` | No | `opencode`. |
| `plane_url` | No | `ws://127.0.0.1:8090/agent`. |

`command` must be a string. It is trimmed. A blank string fails with `<path> command must not be blank.` A value that is not a string fails with `<path> command must be a string.`

A command is accepted when it is a bare name or an absolute path. A bare name contains neither `/` nor `\`, and it is not `.`, `..`, or a drive-relative form such as `C:opencode`. An absolute path starts with `/`, starts with `\\`, or starts with a drive letter, a colon, and a slash. That slash may be `/` or `\`. `./opencode`, `bin/kimi`, a single leading `\`, and `\opencode` are relative and fail with `<path> command must be an absolute path or a bare name.` The check does not search `PATH` and does not require the path to exist. The open step later resolves a bare name with `System.find_executable/1` and requires a regular file. The Unix execute bit is not checked.

`args` must be a list of strings. `[]` is valid. Each string is kept as written. Any other shape fails with `<path> args must be a list of strings.`

A missing file fails with text that begins `No link file at`. A file that is not a JSON object fails with `<path> is not a JSON object.`

## Name, label, and program

`name` is slugged before the uplink dials. Letters become lowercase. Each run of characters other than letters and digits becomes one `-`. Dashes at the ends are removed. At most 40 characters are kept. `Lab Box` becomes `lab-box`. An empty slug is replaced with `opencode`. When `name` and `label` are both missing, the slug of `this machine` is `this-machine`, so the dialed name is `this-machine`.

The plane accepts a hello name of 1 to 40 characters that matches `^[a-z0-9][a-z0-9_-]{0,39}$`. Any other name is closed with code 4003. The slug is built to pass that check. Two files whose slugs match are the same name.

`label` is the display name. On hello the plane stores at most 80 characters of `label` and at most 80 characters of `program`. A blank stored label falls back to the name. A blank stored program falls back to `opencode`. `program` does not select `command`.

## The plane_url field

`plane_url` chooses the scheme, the host, the port, and the path. `wss` and `https` use TLS. The default port for those schemes is 443. `ws` and `http` stay plain. The default port for those schemes is 80. A missing path becomes `/agent` for the uplink. A missing host becomes `127.0.0.1`. The query string is ignored.

The uplink rereads this file every 1000 milliseconds. A change to `name`, `label`, `program`, or `plane_url` is visible on that read. A change to only `command` or `args` is visible on the next start of the relay. [Lifecycle](../explanation/lifecycle.md) describes which start that is.
