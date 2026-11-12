# Release script interfaces

These commands use Python's standard library to package an Erlang/OTP runtime. ERTS is the Erlang runtime system. EPMD is Erlang's port mapper daemon. All positional arguments are required and have no defaults.

| Command | Inputs and result |
| --- | --- |
| `python3 .github/scripts/package_release.py inventory RELEASE OTP` | `RELEASE` is the assembled Mix release directory. `OTP` is the installed OTP root. The command writes the generated `erts` version and `apps` directory list to `RELEASE/runtime.json`. Neither metadata field has a default. The base artifact includes that file so the package step can read it. |
| `python3 .github/scripts/package_release.py package RELEASE OTP TARGET OUTPUT` | The command copies the shared release, replaces its runtime from `OTP`, removes `runtime.json`, and writes an archive in `OUTPUT`. The archive does not contain `runtime.json`. `TARGET` selects the archive name. A `windows-` prefix selects zip. Other targets select tar and gzip. |
| `python3 .github/scripts/smoke_release.py ARCHIVE_DIRECTORY` | The directory must contain exactly one archive. The command extracts it under a temporary path containing spaces, checks both help commands, and starts and stops a plane. |

Runtime replacement rejects different ERTS or OTP application versions before modifying the copy. It preserves the relocatable `bin/erl` that Mix generated and removes `erl.ini`. Target OTP applications replace their Linux counterparts, including platform files. Project and dependency code remains unchanged.

On Unix and Windows, one reader keeps reading the plane's stdout until the process closes it, including during shutdown. On Unix, the smoke test waits for the listener log, records the VM's direct child pids and start times, sends `SIGTERM`, checks exit status zero, checks that the process group is gone, and checks that each recorded child is gone. Linux reads `/proc/<pid>/task/*/children`. macOS reads `ps` pid and ppid columns and keeps rows for that parent. On Windows, the test starts a foreground EPMD on a private port, starts the plane with a unique node name, gets the Erlang process's pid through the release command, and stops it through `bin/agentlink.bat stop`. A Windows process handle and creation time identify that process through shutdown. The test waits for the Erlang process and launcher to exit with status zero, then stops and waits for its EPMD process. Error cleanup targets only those owned processes. The workflow timeout bounds a stuck smoke test.

`.github/release-targets.json` supplies the workflow matrix's `include` list. Every entry requires `target` and `runner`, with no defaults. Each entry packages and smoke-tests the same artifact in one native-runner job. `.tool-versions` is the shared source for the required `erlang` and `elixir` pins.
