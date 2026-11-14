# Stop AgentLink

Distribution is off unless you set it. `bin/agentlink stop`, `remote`, `rpc`, and `pid` need distribution, so they do nothing useful on a default release. [Release packaging](../explanation/release.md) explains that default.

## Stop with a signal

On Linux or macOS, send `SIGTERM` to the release process. That stops `agentlink`, `agentlink plane`, and `agentlink relay`. The application shuts down before the VM exits.

`agentlink connect` treats `SIGTERM` as a failure. The process logs `SIGTERM received - shutting down` and exits with status 1.

`SIGINT` opens the Erlang BREAK prompt in every mode, including connect. That is the same prompt as a plain release. It does not run the application shutdown.

## Stop on Windows

Press Ctrl+C in the release console. At the `BREAK` prompt, press `a`. That aborts the VM and skips a graceful application shutdown.

`bin/agentlink.bat stop` needs the same distribution settings as `bin/agentlink stop`.

## Enable stop, remote, rpc, and pid

Set `RELEASE_DISTRIBUTION=sname` and a unique `RELEASE_NODE` on the running release and on the command that talks to it. Two releases on one machine need different node names. With those variables set, `bin/agentlink stop` shuts the node down.

[Agent process](../agent.md#release-stop) describes the signal handler inside the VM.
