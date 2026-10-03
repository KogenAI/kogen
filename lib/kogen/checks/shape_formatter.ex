defmodule Kogen.Checks.ShapeFormatter do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc

  @format_timeout_ms 120_000

  @spec format_files(
          Path.t(),
          String.t(),
          [Path.t()],
          Path.t(),
          %{String.t() => String.t()},
          Kogen.Proc.Sandbox.t() | nil
        ) :: :ok | {:error, Failure.t()}
  def format_files(workdir, slug, written_paths, run_dir, env, sandbox) do
    expected_paths = [intent_path(slug), acceptance_path(slug)]

    files =
      written_paths
      |> Enum.filter(&(&1 in expected_paths and source_file?(&1)))
      |> Enum.filter(&File.regular?(Path.join(workdir, &1)))

    case files do
      [] ->
        :ok

      _files ->
        run_formatter(workdir, files, run_dir, env, sandbox)
    end
  end

  defp run_formatter(workdir, files, run_dir, env, sandbox) do
    with :ok <- prepare_logs(run_dir) do
      log_path = Path.join([run_dir, "logs", "shape-format.log"])
      argv = ["mix", "format" | files]

      case Proc.run(argv,
             cd: workdir,
             env: env,
             timeout_ms: @format_timeout_ms,
             log_path: log_path,
             sandbox: sandbox
           ) do
        {:ok, %ProcResult{exit_status: 0, timed_out: false}} ->
          :ok

        {:ok, %ProcResult{} = result} ->
          {:error, formatter_failure(files, result)}

        {:error, :enoent} ->
          {:error, failure(:environment, :tool_missing, "mix formatter executable was not found")}

        {:error, reason} ->
          {:error,
           failure(:environment, :format_failed, "mix format could not run: #{inspect(reason)}")}
      end
    end
  end

  defp formatter_failure(files, %ProcResult{} = result) do
    status = if result.timed_out, do: "timed out", else: "exited #{inspect(result.exit_status)}"

    failure(
      :candidate,
      :format_failed,
      "mix format #{Enum.join(files, " ")} #{status}.\n" <> result.output_tail
    )
  end

  defp prepare_logs(run_dir) do
    case File.mkdir_p(Path.join(run_dir, "logs")) do
      :ok -> :ok
      {:error, reason} -> {:error, failure(:environment, :log_directory_failed, inspect(reason))}
    end
  end

  defp source_file?(path), do: Path.extname(path) in [".ex", ".exs"]

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp acceptance_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
