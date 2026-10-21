# Bridge

Elixir control plane and sidecar that proxy ACP between apps and agent runtimes. The web UI is not in this directory.

Mix. `mix test` skips `:integration`. The OpenCode test is `mix test --only integration`.

Read the matching file when the task touches that area:

- [Structs](docs/structs.md) when a value has a fixed shape
- [GenServers](docs/genservers.md) when adding a client call or a callback
- [Names](docs/names.md) when adding a module or a pid field
- [Harness](docs/harness.md) when the sidecar opens an agent
