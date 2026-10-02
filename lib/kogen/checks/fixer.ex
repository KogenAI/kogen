defmodule Kogen.Checks.Fixer do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Project
  alias Kogen.Proc

  @spec run(Path.t(), Project.t(), Path.t()) :: {:ok, [ProcResult.t()]} | {:error, Failure.t()}
  def run(workdir, %Project{} = project, run_dir) do
    with :ok <- prepare_logs(run_dir) do
      run_specs(project.fix, workdir, run_dir, 1, [])
    end
  end

  defp run_specs([], _workdir, _run_dir, _index, results), do: {:ok, Enum.reverse(results)}

  defp run_specs([spec | rest], workdir, run_dir, index, results) do
    log_path = Path.join([run_dir, "logs", "fix-#{index}-#{safe_name(spec.name)}.log"])

    case Proc.run(spec.argv, cd: workdir, timeout_ms: spec.timeout_ms, log_path: log_path) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false} = result} ->
        run_specs(rest, workdir, run_dir, index + 1, [result | results])

      {:ok, %ProcResult{timed_out: true}} ->
        {:error, failure(:candidate, :fix_timeout, "safe formatter timed out: #{spec.name}")}

      {:ok, %ProcResult{exit_status: status}} ->
        {:error,
         failure(:candidate, :fix_failed, "safe formatter #{spec.name} exited #{inspect(status)}")}

      {:error, :enoent} ->
        {:error,
         failure(:environment, :tool_missing, "safe formatter tool missing: #{spec.name}")}

      {:error, reason} ->
        {:error,
         failure(:environment, :process_failed, "safe formatter #{spec.name}: #{inspect(reason)}")}
    end
  end

  defp prepare_logs(run_dir) do
    if Path.type(run_dir) == :absolute do
      case File.mkdir_p(Path.join(run_dir, "logs")) do
        :ok -> :ok
        {:error, reason} -> {:error, failure(:environment, :log_directory, inspect(reason))}
      end
    else
      {:error, failure(:controller, :invalid_run_dir, "run directory must be absolute")}
    end
  end

  defp safe_name(name), do: Regex.replace(~r/[^A-Za-z0-9_.-]/, name, "_")
  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
