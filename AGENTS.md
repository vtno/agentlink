# AgentLink

AgentLink is the control plane and the agent relay. It proxies ACP between apps and agent runtimes.

Mix. `mix test` excludes tests tagged `:wrapped` and `:release`. The OpenCode test is `AGENTLINK_BIN=./_build/prod/rel/agentlink/bin/agentlink OPENCODE_BIN=/path/to/opencode mix test --only wrapped`.

Read the matching file when the task touches that area:

- [Glossary](docs/glossary.md) when naming a connection, a process, or a module
- [Structs](docs/structs.md) when a value has a fixed shape
- [GenServers](docs/genservers.md) when adding a client call or a callback
- [Names](docs/names.md) when adding a module or a pid field
- [Agent](docs/agent.md) when the agent relay opens an agent
