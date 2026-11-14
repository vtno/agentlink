defmodule AgentLink.MixProject do
  use Mix.Project

  # OTP 27 rejects the Linux `user_timeout` inet option the uplink passes
  # to `:gen_tcp.connect/4`, so the relay only runs on OTP 29.
  required_otp = 29
  otp_release = :erlang.system_info(:otp_release) |> List.to_string()

  case Integer.parse(otp_release) do
    {major, _rest} when major >= required_otp ->
      :ok

    _other ->
      Mix.raise("AgentLink requires Erlang/OTP #{required_otp}. Found OTP #{otp_release}.")
  end

  def project do
    [
      app: :agent_link,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases(),
      package: package()
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
      {:floki, "~> 0.37", only: :test}
    ]
  end

  defp releases do
    [
      agentlink: [
        steps: [:assemble, &AgentLink.Release.forward_start_args/1]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end
end
