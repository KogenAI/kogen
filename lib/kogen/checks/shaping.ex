defmodule Kogen.Checks.Shaping.StageFile do
  @moduledoc false

  @enforce_keys [:path, :restore, :created_dirs]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: Path.t(),
          restore: :remove | :unchanged | {:write, binary()},
          created_dirs: [Path.t()]
        }
end

defmodule Kogen.Checks.Shaping do
  @moduledoc false

  alias Kogen.Checks.Ledger
  alias Kogen.Checks.ShapeValidation
  alias Kogen.Checks.Shaping.StageFile
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Workspace

  @spec validate(ShapeValidation.t()) :: :ok | {:error, Failure.t()}
  def validate(%ShapeValidation{} = request) do
    case stage_test(request.workdir, request.intent.slug, request.acceptance_bytes) do
      {:ok, %StageFile{} = staged} ->
        result = verify(request)
        cleanup_result(result, cleanup(staged))

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp verify(%ShapeValidation{} = request) do
    with :ok <-
           acceptance_checks(
             request.workdir,
             request.project,
             request.intent.slug,
             request.run_dir,
             Map.merge(request.env, request.project.env),
             request.git_env
           ) do
      red_on_base(
        request.workdir,
        request.intent,
        request.run_dir,
        request.env,
        request.git_env
      )
    end
  end

  defp acceptance_checks(workdir, project, slug, run_dir, env, git_env) do
    with :ok <- prepare_logs(run_dir),
         {:ok, before_tree} <- Workspace.tree_hash(workdir, git_env),
         result = run_specs(project.acceptance_checks, workdir, slug, run_dir, env),
         {:ok, after_tree} <- Workspace.tree_hash(workdir, git_env),
         :ok <- unchanged_tree(before_tree, after_tree),
         :ok <- result do
      :ok
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, failure(:controller, :acceptance_check_setup, inspect(reason))}
    end
  end

  defp run_specs(specs, workdir, slug, run_dir, env) do
    relative = "test/acceptance/#{slug}_test.exs"

    Enum.reduce_while(Enum.with_index(specs, 1), :ok, fn {spec, index}, :ok ->
      case run_spec(spec, workdir, relative, run_dir, env, index) do
        :ok -> {:cont, :ok}
        {:error, %Failure{} = failure} -> {:halt, {:error, failure}}
      end
    end)
  end

  defp run_spec(spec, workdir, relative, run_dir, env, index) do
    argv = Enum.map(spec.argv, &String.replace(&1, "{path}", relative))
    log_path = Path.join([run_dir, "logs", "shape-acceptance-#{index}-#{spec.name}.log"])

    case Proc.run(argv, cd: workdir, env: env, timeout_ms: spec.timeout_ms, log_path: log_path) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false}} ->
        :ok

      {:ok, %ProcResult{} = result} ->
        {:error, check_failure(spec.name, result)}

      {:error, :enoent} ->
        {:error,
         failure(
           :environment,
           :tool_missing,
           "Acceptance check #{spec.name} executable was not found."
         )}

      {:error, reason} ->
        {:error,
         failure(
           :environment,
           :acceptance_check_failed,
           "Acceptance check #{spec.name} could not run: #{inspect(reason)}"
         )}
    end
  end

  defp check_failure(name, %ProcResult{} = result) do
    status = if result.timed_out, do: "timed out", else: "exited #{result.exit_status}"
    detail = "Acceptance check #{name} #{status}.\n" <> result.output_tail
    failure(:candidate, :acceptance_check_failed, detail)
  end

  defp red_on_base(workdir, intent, run_dir, env, git_env) do
    case Ledger.red_on_base(workdir, intent, run_dir, env, git_env) do
      :ok -> :ok
      {:error, %Failure{} = failure} -> {:error, failure}
    end
  end

  defp stage_test(workdir, slug, contents) do
    path = Path.join([workdir, "test", "acceptance", "#{slug}_test.exs"])

    with :ok <- valid_stage_target(workdir, slug),
         {:ok, created_dirs} <- ensure_directories(workdir) do
      case write_stage(path, contents) do
        {:ok, restore} ->
          {:ok, %StageFile{path: path, restore: restore, created_dirs: created_dirs}}

        {:error, %Failure{} = failure} ->
          cleanup_stage_error(failure, created_dirs)
      end
    else
      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp valid_stage_target(workdir, slug) do
    valid_slug = is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
    root = if is_binary(workdir), do: File.lstat(workdir), else: {:error, :invalid_root}

    case {valid_slug, root} do
      {true, {:ok, %File.Stat{type: :directory}}} ->
        :ok

      {false, _root} ->
        {:error,
         failure(:candidate, :invalid_slug, "Intent slug cannot name an acceptance test.")}

      {_valid, _root} ->
        {:error,
         failure(:environment, :invalid_workdir, "Project checkout must be a real directory.")}
    end
  end

  defp ensure_directories(workdir) do
    result =
      Enum.reduce_while(["test", "test/acceptance"], {:ok, []}, fn relative, {:ok, created} ->
        ensure_directory(Path.join(workdir, relative), created)
      end)

    case result do
      {:ok, created} -> {:ok, created}
      {:error, %Failure{} = failure, created} -> cleanup_stage_error(failure, created)
    end
  end

  defp ensure_directory(path, created) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:cont, {:ok, created}}

      {:ok, _stat} ->
        unsafe =
          failure(
            :environment,
            :unsafe_acceptance_path,
            "Acceptance path contains a non-directory component."
          )

        {:halt, {:error, unsafe, created}}

      {:error, :enoent} ->
        create_directory(path, created)

      {:error, reason} ->
        unavailable = failure(:environment, :acceptance_path_unavailable, inspect(reason))
        {:halt, {:error, unavailable, created}}
    end
  end

  defp create_directory(path, created) do
    case File.mkdir(path) do
      :ok ->
        {:cont, {:ok, [path | created]}}

      {:error, reason} ->
        unavailable = failure(:environment, :acceptance_path_unavailable, inspect(reason))
        {:halt, {:error, unavailable, created}}
    end
  end

  defp write_stage(path, contents) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        overwrite_stage(path, contents)

      {:ok, _stat} ->
        {:error,
         failure(
           :environment,
           :unsafe_acceptance_path,
           "Acceptance test path is not a regular file."
         )}

      {:error, :enoent} ->
        create_stage(path, contents)

      {:error, reason} ->
        {:error, failure(:environment, :acceptance_stage_failed, inspect(reason))}
    end
  end

  defp overwrite_stage(path, contents) do
    with {:ok, original} <- File.read(path),
         :ok <- File.write(path, contents, [:binary]) do
      restore = if original == contents, do: :unchanged, else: {:write, original}
      {:ok, restore}
    else
      {:error, reason} ->
        {:error, failure(:environment, :acceptance_stage_failed, inspect(reason))}
    end
  end

  defp create_stage(path, contents) do
    case File.write(path, contents, [:binary, :exclusive]) do
      :ok ->
        {:ok, :remove}

      {:error, reason} ->
        {:error, failure(:environment, :acceptance_stage_failed, inspect(reason))}
    end
  end

  defp cleanup(%StageFile{} = staged) do
    file_result = restore_file(staged.path, staged.restore)
    directory_result = remove_directories(staged.created_dirs)

    case {file_result, directory_result} do
      {:ok, :ok} ->
        :ok

      {file_error, directory_error} ->
        detail =
          Enum.reject([format_cleanup(file_error), format_cleanup(directory_error)], &is_nil/1)

        {:error, failure(:environment, :acceptance_cleanup_failed, Enum.join(detail, "\n"))}
    end
  end

  defp cleanup_stage_error(%Failure{} = original, created_dirs) do
    case remove_directories(created_dirs) do
      :ok ->
        {:error, original}

      {:error, reason} ->
        {:error,
         %{
           original
           | detail:
               original.detail <> "\nTemporary directory cleanup failed: " <> inspect(reason)
         }}
    end
  end

  defp restore_file(_path, :unchanged), do: :ok

  defp restore_file(path, {:write, contents}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.write(path, contents, [:binary])
      {:ok, _stat} -> {:error, :unsafe_restore_target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_file(path, :remove) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_directories(created_dirs) do
    Enum.reduce_while(created_dirs, :ok, fn path, :ok ->
      case File.rmdir(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp prepare_logs(run_dir) do
    case File.mkdir_p(Path.join(run_dir, "logs")) do
      :ok -> :ok
      {:error, reason} -> {:error, failure(:environment, :log_directory_failed, inspect(reason))}
    end
  end

  defp format_cleanup(:ok), do: nil
  defp format_cleanup({:error, reason}), do: inspect(reason)

  defp unchanged_tree(tree, tree), do: :ok

  defp unchanged_tree(_before, _after),
    do:
      {:error,
       failure(:candidate, :tree_mutated, "An acceptance check changed the project tree.")}

  defp cleanup_result(result, :ok), do: result

  defp cleanup_result({:error, %Failure{} = original}, {:error, %Failure{} = cleanup}),
    do:
      {:error,
       %{cleanup | detail: cleanup.detail <> "\nOriginal validation failure: " <> original.detail}}

  defp cleanup_result(_result, {:error, %Failure{} = cleanup}), do: {:error, cleanup}

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
