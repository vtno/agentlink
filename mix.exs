defmodule AgentLink.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_link,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    extras = [extra_applications: [:logger]]

    if Mix.env() == :test do
      extras
    else
      Keyword.put(extras, :mod, {AgentLink.Application, []})
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:floki, "~> 0.37", only: :test},
      # PR #230 (fix/dont-let-elixir-cli-consume-app-args). Not released.
      # The launcher passes `--no-halt --` so Elixir's CLI does not halt.
      {:burrito,
       github: "joshrotenberg/burrito",
       ref: "f2d437041418abb9073a6d7588d22835a04ee7cb",
       runtime: false}
    ]
  end

  defp releases do
    steps = [:assemble, &AgentLink.Release.forward_start_args/1]

    steps =
      if System.get_env("AGENTLINK_BURRITO") == "0" do
        steps
      else
        steps ++ [&AgentLink.Release.wrap_burrito/1, &AgentLink.Release.forward_signals/1]
      end

    [
      agentlink: [
        steps: steps,
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            macos: [os: :darwin, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
