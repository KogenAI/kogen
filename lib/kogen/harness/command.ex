defmodule Kogen.Harness.Command do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Harness.Error
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Paths

  @spec run(Opts.t(), [String.t()], pos_integer(), String.t()) ::
          {:ok, ProcResult.t()} | {:error, Error.t()}
  def run(%Opts{} = opts, argv, timeout_ms, label) do
    with {:ok, run_dir} <- Paths.run_dir(opts),
         :ok <- File.mkdir_p(Path.join(run_dir, "logs")) do
      log_path = Path.join([run_dir, "logs", "#{safe_label(label)}-#{unique_id()}.log"])

      case opts.proc_mod.run(argv,
             cd: opts.workdir,
             env: opts.env,
             timeout_ms: timeout_ms,
             log_path: log_path
           ) do
        {:ok, %ProcResult{} = result} ->
          {:ok, result}

        {:error, :enoent} ->
          error(:command_missing, "Command was not found on the explicit PATH.")

        {:error, reason} ->
          error(:process_failed, "Process could not run: #{inspect(reason)}")
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        error(:log_directory_failed, "Cannot create run log directory: #{inspect(reason)}")
    end
  end

  defp safe_label(label), do: Regex.replace(~r/[^A-Za-z0-9_-]/, label, "-")
  defp unique_id, do: System.unique_integer([:positive, :monotonic])
  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
