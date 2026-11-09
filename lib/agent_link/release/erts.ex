defmodule AgentLink.Release.ERTS do
  @moduledoc """
  Resolves the Burrito ERTS when the published tarball for this OTP is missing.

  Burrito's default resolver downloads a precompiled OTP that matches the host
  version and raises when that URL returns 404. `do_resolve/1` tries that
  download. When the target is this machine's OS and CPU and the error is a
  404, the Linux wrap uses the unpacked ERTS at `:code.root_dir/0`. That tree
  is the OTP the VM is already running, so its NIFs stay the ones shipped with
  that OTP. A 404 for any other target is raised again. `AgentLink.Release.wrap_burrito/1`
  drops those other targets before the build when their URL returns 404, and
  the plain Mix release still succeeds.
  """

  @behaviour Burrito.Util.ERTSResolver

  alias Burrito.Builder.Target

  @impl true
  def do_resolve(%Target{} = target) do
    try do
      Burrito.Util.DefaultERTSResolver.do_resolve(target)
    rescue
      error in RuntimeError ->
        case decide(target, Exception.message(error)) do
          {:local, path} ->
            Burrito.Builder.Log.warning(
              :step,
              "No published OTP for #{target.os} #{target.cpu}. Using the local ERTS at #{path}."
            )

            %Target{target | erts_source: {:local_unpacked, path: path}}

          :raise ->
            reraise error, __STACKTRACE__
        end
    end
  end

  @doc """
  Choose a local ERTS when `message` is a 404 for this machine's OS and CPU.

  Returns `{:local, path}` or `:raise`.
  """
  @spec decide(Target.t(), String.t()) :: {:local, String.t()} | :raise
  def decide(%Target{os: os, cpu: cpu}, message) when is_binary(message) do
    host? = os == Burrito.Util.get_current_os() and cpu == Burrito.Util.get_current_cpu()

    if host? and String.contains?(message, "404") do
      {:local, to_string(:code.root_dir())}
    else
      :raise
    end
  end
end
