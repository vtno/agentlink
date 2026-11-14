# Release packaging

The published archive is a Mix release with its own Erlang runtime, so the machine that runs AgentLink does not need Elixir installed. The project code is compiled once. Each target then swaps the runtime rather than compiling Elixir again on that operating system.

## One build, five runtimes

`.tool-versions` pins OTP 29.1.2 and Elixir 1.20.4 for the workflows. `mix.exs` requires `~> 1.17`. The release workflow builds `MIX_ENV=prod mix release` once on Linux. `config/runtime.exs` is not in the repository, so the release uses the values compiled from `config/config.exs` and skips runtime configuration.

Each target downloads that artifact and replaces ERTS and the matching OTP applications with the prebuilt runtime from `erlef/setup-beam`. Project and dependency BEAM files stay as compiled. The packager keeps the relocatable `erl` script Mix wrote and removes the installation-specific `erl.ini`. It writes `runtime.json` only so the package step can see the ERTS version and the OTP application list, then deletes that file. The published archive does not contain `runtime.json`.

`.github/release-targets.json` names the targets and their runners. The archive names are `agentlink-linux-x86_64.tar.gz`, `agentlink-linux-aarch64.tar.gz`, `agentlink-macos-x86_64.tar.gz`, `agentlink-macos-arm64.tar.gz`, and `agentlink-windows-x86_64.zip`. Linux and macOS archives are gzip tarballs. The Windows archive is a zip file. A local `mix release` produces a directory, not one of those archives. The directory contains `bin/agentlink`, `bin/agentlink.bat`, `erts-<version>`, `lib`, and `releases`.

A tag that starts with `v` publishes those archives and `SHA256SUMS` only after every matrix job passes. Pushes to `main`, manual runs, and pull requests that change release files build and smoke-test without publishing. The packager commands are in [Release script interfaces](../../.github/scripts/README.md).

## Why the launcher is patched

Mix's stock `bin/agentlink` treats unknown words as an error and would not pass `plane`, `relay`, or `connect` into the VM. The release step rewrites the Unix and Windows scripts so those words are placed after `--`. On a release boot the CLI keeps the words after the first bare `--`.

`bin/agentlink` with no words leaves the configured mode in place. That mode is `:all`, so the plane and the relay both start. `bin/agentlink start` also boots the release and passes the words after `start`.

`bin/agentlink.bat` places `%*` after `--` with delayed expansion off, so a quoted argument stays one argument. `bin/agentlink.bat start` sets `AGENTLINK_WINDOWS_START=1` because `%*` still begins with `start`. The CLI drops one leading `start` only when the OS is Windows and that variable is `1`. A direct `plane`, `relay`, or `connect` does not set the variable. `start start` is a usage error. The test suite checks the Windows script as text and does not run it on Windows.

## Why distribution is off

`rel/env.sh.eex` sets `RELEASE_DISTRIBUTION` to `none` when you do not override it. Release processes then do not need unique Erlang node names, and a second relay on one machine does not collide with the first. `stop`, `remote`, `rpc`, and `pid` cannot address the node. Set `RELEASE_DISTRIBUTION=sname` and a unique `RELEASE_NODE` on both the running release and the command when you need those. [Stop AgentLink](../how-to/stop-agentlink.md) is the procedure without distribution, and with it.
