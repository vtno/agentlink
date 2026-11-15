# HTTP routes

The plane serves these GET routes on the listen port. The default port is 8090. The bind address is `127.0.0.1`. No other method or path is defined.

| Request | Token | Result |
| --- | --- | --- |
| `GET /health` | Not read | Status 200. The body is `ok`. |
| `GET /status` | Required | Status 200. The body is JSON. The content type is `application/json`. |
| `GET /acp` | Required | WebSocket for a client. The idle timeout is infinity. |
| `GET /agent` | Required | WebSocket for an uplink. The idle timeout is infinity. |

A rejected token is status 401 and the body `unauthorized`. Any other path is status 404 and the body `not found`.

The token is the `Authorization` header or the `token` query parameter. The header value is `Bearer <token>` or `bearer <token>`. When `token` is present and not empty, that value is used and the header is not read. [Security model](../explanation/security.md) describes the comparison.

## Status body

The JSON object has two keys.

`plane` is the text `127.0.0.1:` followed by the listen port.

`runtimes` is the list `AgentLink.Access` allows for this caller. Under `AgentLink.Access.Single`, an admin receives every uplink. Each entry has `name`, `label`, `program`, and `connected_at`. `connected_at` is seconds since 1970-01-01 00:00:00 UTC. The list is sorted by `name`.

An empty `runtimes` list means no allowed uplink is connected. It is still status 200.
