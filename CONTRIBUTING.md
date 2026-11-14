# Contributing

This repository is tested with Elixir 1.20.4 and Erlang 29.1.2. `mix.exs` requires `~> 1.17`.

## Format the code

Run `mix format`.

Run `mix format --check-formatted` to check without writing files.

## Compile

Run `mix compile --warnings-as-errors`.

## Run the tests

Run `mix deps.get`.

Run `mix test`.

`mix test` does not start a provider. It excludes tests tagged `:wrapped` and `:release`.

Run `mix test --only release` to build a production release and check `bin/agentlink`, `bin/agentlink plane`, `bin/agentlink relay`, and `bin/agentlink connect`, including pid and process-group `SIGTERM`. Those tests are written for Linux. The suite checks `bin/agentlink.bat` as text and does not run it on Windows. [Release packaging](docs/explanation/release.md) describes the launcher, and [Agent process](docs/agent.md#release-stop) describes the signal handler.

Run the packager checks. They use temporary directories and do not start a release.

```sh
python3 -m unittest discover -s .github/scripts -p 'test_*.py'
```

To run the OpenCode test, set `AGENTLINK_BIN` to the release binary and `OPENCODE_BIN` to the OpenCode binary. The test starts that release, asks OpenCode to write an HTML page, and checks the page.

```sh
AGENTLINK_BIN=./_build/prod/rel/agentlink/bin/agentlink OPENCODE_BIN=/path/to/opencode mix test --only wrapped
```
