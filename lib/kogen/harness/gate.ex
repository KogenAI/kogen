defmodule Kogen.Harness.Gate do
  @moduledoc false

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Harness.Command
  alias Kogen.Harness.Error
  alias Kogen.Harness.GateCommand
  alias Kogen.Harness.GateResult
  alias Kogen.Harness.Opts

  @spec run(Opts.t(), integer()) :: {:ok, GateResult.t()} | {:error, Error.t()}
  def run(%Opts{} = opts, deadline) do
    with {:ok, fixes} <- run_specs(opts, opts.project.fix, deadline, :fix),
         {:ok, checks} <- run_specs(opts, opts.project.checks, deadline, :check) do
      commands = fixes ++ checks
      failures = Enum.flat_map(commands, &failure_text/1)
      status = if failures == [], do: :pass, else: :fail
      {:ok, %GateResult{status: status, fixes: fixes, checks: checks, failures: failures}}
    end
  end

  defp run_specs(opts, specs, deadline, kind) do
    specs
    |> Enum.reduce_while({:ok, []}, fn %CheckSpec{} = spec, {:ok, results} ->
      result = run_spec(opts, spec, deadline, kind)
      {:cont, {:ok, [result | results]}}
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp run_spec(opts, %CheckSpec{} = spec, deadline, kind) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      %GateCommand{
        name: spec.name,
        exit_status: nil,
        timed_out: true,
        output: "Harness wall deadline reached before this command ran."
      }
    else
      run_command(opts, spec, min(spec.timeout_ms, remaining_ms), kind)
    end
  end

  defp run_command(opts, spec, timeout_ms, kind) do
    case Command.run(opts, spec.argv, timeout_ms, "gate-#{kind}-#{spec.name}") do
      {:ok, result} ->
        %GateCommand{
          name: spec.name,
          exit_status: result.exit_status,
          timed_out: result.timed_out,
          output: clip_tail(result.output_tail)
        }

      {:error, %Error{} = error} ->
        %GateCommand{name: spec.name, exit_status: nil, timed_out: false, output: error.detail}
    end
  end

  defp failure_text(%GateCommand{timed_out: true} = command),
    do: ["#{command.name} timed out.\n#{command.output}"]

  defp failure_text(%GateCommand{exit_status: status} = command) when status != 0,
    do: ["#{command.name} exited #{inspect(status)}.\n#{command.output}"]

  defp failure_text(_command), do: []

  defp clip_tail(output) do
    if String.valid?(output) do
      if String.length(output) > 10_000,
        do: String.slice(output, String.length(output) - 10_000, 10_000),
        else: output
    else
      tail = binary_part(output, max(byte_size(output) - 7_400, 0), min(byte_size(output), 7_400))
      "[non-UTF-8 output tail, base64 encoded]\n" <> Base.encode64(tail)
    end
  end
end
