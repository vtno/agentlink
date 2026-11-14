# Security model

AgentLink ships with one operator and one token. The token identifies the caller. It does not encrypt the socket. The listener is plain HTTP on localhost. An ssh tunnel or a TLS proxy encrypts the path from another machine. Terminating TLS inside the VM would not stop that proxy from logging `?token=`.

## One token

`AgentLink.Access.Single` is the policy. The subject for the configured token is an admin. That admin may use every uplink. Create the token before startup. AgentLink does not generate it and does not print it. Startup text says that the configured token is in use and stops there.

A caller presents the token in the `Authorization` header or in `?token=`. The header scheme is `Bearer` or `bearer`. When `?token=` is present and not empty, that value is the token and the header is not read. The comparison is a constant-time compare of the raw bytes.

The uplink sends the header. It does not put the token in `plane_url`, and it ignores any query string on that URL. Prefer the header. A proxy can store `?token=` in its access log. Turn query logging off before you proxy the plane.

`GET /health` does not read the token. `GET /acp`, `GET /agent`, and `GET /status` require it. A rejected token is status 401 and the body `unauthorized`. [HTTP routes](../reference/http.md) lists the paths.

`--token` puts the secret in the process command line. Use `AGENTLINK_TOKEN` or `$HOME/.agentlink/token` instead. The file must be a regular file in mode `0600`, `0400`, `0200`, or `0000`.

The listener binds `127.0.0.1` only. A relay on another machine reaches it through a tunnel or a TLS proxy. Do not publish the listen port. [Reach a plane on another machine](../how-to/reach-another-machine.md) has the routes.

## Replacing the policy

`AgentLink.Access` is the extension point. Set the `:access` application environment to another module to replace `AgentLink.Access.Single`. That module implements `authenticate/1`, `allowed?/2`, and `prepare/1`. `claim/2` is optional. A policy without `claim/2` accepts the hello. `:reject` from `claim/2` closes the uplink with code 4004.

This build has one shared token. Per-machine tokens and revocation are not implemented. [Set the token](../how-to/set-the-token.md) is how you create the secret this policy uses.

Report a vulnerability in private. The scope and the reporting URL are in [Security policy](../../SECURITY.md).
