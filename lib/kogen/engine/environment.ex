defmodule Kogen.Engine.Environment do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.ProcResult
  alias Kogen.Engine.Runtime
  alias Kogen.Proc

  @spec project(Path.t(), Runtime.t()) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, :invalid_toolchain_environment | {:toolchain_failed, String.t()}}
  def project(workdir, %Runtime{} = runtime) do
    case Proc.run(
           [runtime.mise, "env", "-C", workdir, "--json", "--quiet"],
           cd: workdir,
           env: runtime.base_env,
           timeout_ms: 30_000
         ) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false, output_tail: output}} ->
        decode_environment(output, runtime)

      {:ok, %ProcResult{output_tail: output}} ->
        {:error, {:toolchain_failed, toolchain_failure_detail(output)}}

      {:error, reason} ->
        {:error, {:toolchain_failed, "mise env failed: #{inspect(reason)}"}}
    end
  end

  defp toolchain_failure_detail(output) do
    output = Runtime.output_tail(output)
    if output == "", do: "mise env failed", else: "mise env failed:\n" <> output
  end

  defp decode_environment(output, runtime) do
    case JSON.decode(output) do
      {:ok, values} when is_map(values) ->
        with {:ok, env} <- string_environment(values) do
          {:ok, Runtime.process_env(runtime, env)}
        end

      _other ->
        {:error, :invalid_toolchain_environment}
    end
  end

  defp string_environment(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, env} ->
      if is_binary(key) and is_binary(value) do
        {:cont, {:ok, Map.put(env, key, value)}}
      else
        {:halt, {:error, :invalid_toolchain_environment}}
      end
    end)
  end
end
