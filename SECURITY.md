# Security policy

## Report a vulnerability

Report a vulnerability in private. Use GitHub private vulnerability reporting for vtno/agentlink. That report opens a draft security advisory.

Open the report at https://github.com/vtno/agentlink/security/advisories/new.

Do not open a public issue for a vulnerability.

## Scope

These parts of AgentLink are in scope:

- The plane WebSocket that requires a token. The routes are `GET /acp` and `GET /agent`.
- Token handling in `AgentLink.Auth`. A caller sends the token in the `Authorization` header or in `?token=`.
- The agent process launcher. `AgentLink.Agent.Process` opens `command` and `args` from the link file.

[Security model](docs/explanation/security.md) describes the token and the listener.

## Supported versions

The latest release is the supported version.
