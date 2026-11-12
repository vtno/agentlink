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

`mix test` excludes tests tagged `:wrapped` and `:release`.

Run `mix test --only release` to build a production release and check `bin/agentlink`.

To run the OpenCode test, set `AGENTLINK_BIN` to the release binary and `OPENCODE_BIN` to the OpenCode binary.

```sh
AGENTLINK_BIN=./_build/prod/rel/agentlink/bin/agentlink OPENCODE_BIN=/path/to/opencode mix test --only wrapped
```
