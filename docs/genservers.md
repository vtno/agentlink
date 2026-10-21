# GenServers

Put the client function immediately above the callback it triggers. `start_link` sits above `init`.

Shortcuts that share a callback stay together, in the same order as the clauses under them.

`@doc` says what the call does and why. Do not name the callback in that doc.

WebSock modules have no separate shortcut. Bandit calls `init` and `handle_in` directly, so the `@doc` sits on those callbacks.
