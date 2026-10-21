# Bridge

Elixir conventions for `lib/acp`. The app UI is outside this directory.

## Structs

Use a struct when the shape is ours and more than one function relies on it. GenServer and WebSock state is a struct. `Acp.Link` is a struct because `Uplink` reads it.

A struct is data, not a behaviour. Behaviour is `@behaviour` and `@callback`.

Keep a map at a boundary we do not own. `Jason.decode` returns a map with string keys. Build our struct from the fields we need. ACP messages, a pending call, and a fan-out answer stay maps: they are built in one place, or the other side defines the keys.

## GenServers

Put the client function immediately above the callback it triggers. `start_link` sits above `init`.

Elixir will not allow another function between two clauses of the same callback. Shortcuts that share a callback stay together, in the same order as the clauses under them.

`@doc` says what the call does and why. Do not name the callback (`handle_cast`, `init/1`) in that doc.

WebSock modules have no separate shortcut. Bandit calls `init` and `handle_in` directly, so the `@doc` sits on those callbacks.

## Names

`owner` is the pid that receives inbound ACP. It is not a supervisor. Do not call that field `parent`.

## Harness

Sidecar does not spawn OpenCode itself. It opens the agent through `Acp.Harness`. Production is `Acp.OpenCode`. Tests set `:acp, :harness` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.
