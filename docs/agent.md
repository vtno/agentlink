# Agent

`AgentLink.Relay.Agent` does not spawn OpenCode itself. It opens the agent through `AgentLink.Agent`. `AgentLink.OpenCode` is the production behaviour and runs the binary. Tests set `:agent_link, :agent_module` to a fake so the suite never starts the binary. Stdout still arrives as `{ref, {:data, binary}}`.

`AgentLink.Agent` is that behaviour. A link's `program` is only the product name, such as `opencode`. The name does not choose the module.

`AgentLink.Agent.Launch.load/1` reads `command` and `args` from the link file. The relay does not call `load/1`. `AgentLink.OpenCode` is still the production behaviour.

`AgentLink.Agent.Process.open/3` opens an `AgentLink.Agent.Launch` from the caller. A test calls `open/3` directly. The relay does not call it. `AgentLink.OpenCode` is still the production behaviour. The caller must be `owner`. A bare name is resolved by the finder. `open/4` accepts that finder. The default is `&System.find_executable/1`. A path that is absolute on this host is used unchanged. On Unix that path starts with `/`. On Windows it starts with two slashes, or with a drive letter, a colon, and a slash. Each of those two slashes may be `/` or `\`. The slash after the colon may be `/` or `\`. On Windows, a single leading slash is not absolute. Any other command is rejected before `File.stat/1`. `File.stat/1` must report a regular file. `File.stat/1` follows symlinks. `open/3` then calls `Port.open/2` with `{:spawn_executable, path}`, `:binary`, `:exit_status`, `:use_stdio`, `{:args, args}`, and `{:cd, cwd}`. `:env` is omitted, so the port inherits the VM environment. `:stderr_to_stdout` is omitted, so stderr is not merged into `{port, {:data, binary}}`. `write/2` returns `:ok` when the port is open and `:closed` otherwise. `close/1` returns `:ok`. `close/1` closes the port, which closes the child's stdin. `close/1` does not reap a process tree.

For `session/new` and `session/load`, the relay fills a missing, null, or empty `cwd` in params with its workspace, `AgentLink.Paths.workdir()`, before the message reaches the agent. An explicit `cwd` passes through unchanged.
