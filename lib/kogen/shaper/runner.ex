defmodule Kogen.Shaper.Runner do
  @moduledoc false

  alias Kogen.Checks.ShapeValidation
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.ShapePass
  alias Kogen.Intent, as: IntentDomain
  alias Kogen.Proc
  alias Kogen.Project, as: ProjectDomain
  alias Kogen.Shaper.Request
  alias Kogen.Shaper.Result
  alias Kogen.Shaper.Runner.State

  @max_repairs 2
  @max_turns 12
  @wall_ms 300_000

  @spec run(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Request{} = request) do
    with :ok <- valid_request(request),
         {:ok, project} <- ProjectDomain.load(request.workdir),
         {:ok, opts} <- harness_options(request, project),
         :ok <- setup_project(request, project) do
      attempt(%State{request: request, project: project, opts: opts})
    end
  end

  defp setup_project(request, %Project{} = project) do
    env = Map.merge(request.env, project.env)

    case File.mkdir_p(Path.join(request.run_dir, "logs")) do
      :ok ->
        Enum.reduce_while(Enum.with_index(project.setup, 1), :ok, fn {spec, index}, :ok ->
          run_setup(spec, request, env, index)
        end)

      {:error, reason} ->
        {:error, failure(:environment, :setup_log_failed, inspect(reason))}
    end
  end

  defp run_setup(spec, request, env, index) do
    log_path = Path.join([request.run_dir, "logs", "shape-setup-#{index}-#{spec.name}.log"])

    case Proc.run(spec.argv,
           cd: request.workdir,
           env: env,
           timeout_ms: spec.timeout_ms,
           log_path: log_path
         ) do
      {:ok, %{exit_status: 0, timed_out: false}} ->
        {:cont, :ok}

      {:ok, result} ->
        detail =
          "Setup #{spec.name} failed (status=#{inspect(result.exit_status)}, timed_out=#{result.timed_out}).\n#{result.output_tail}"

        {:halt, {:error, failure(:environment, :setup_failed, detail)}}

      {:error, reason} ->
        {:halt,
         {:error,
          failure(
            :environment,
            :setup_failed,
            "Setup #{spec.name} could not run: #{inspect(reason)}"
          )}}
    end
  end

  defp attempt(%State{} = state) do
    request = state.request

    case Harness.shape(
           state.opts,
           request.slug,
           request.task,
           state.history,
           state.failure_text,
           state.turn_offset
         ) do
      {:ok, %ShapePass{} = pass} ->
        next = %{state | calls: state.calls ++ pass.calls}
        validate_pass(next, pass)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_pass(%State{} = state, %ShapePass{} = pass) do
    case validate_files(state.request, state.project, state.opts) do
      :ok ->
        {:ok, result(state.request, state.calls, state.repairs + 1, state.opts)}

      {:error, %Failure{class: :candidate} = failure} when state.repairs < @max_repairs ->
        repair(state, pass, failure)

      {:error, %Failure{} = failure} ->
        validation_exhausted(failure, state.repairs)
    end
  end

  defp repair(%State{} = state, %ShapePass{} = pass, %Failure{} = failure) do
    next = %{
      state
      | history: pass.items,
        failure_text: failure_output(failure),
        turn_offset: state.turn_offset + pass.turns,
        repairs: state.repairs + 1
    }

    attempt(next)
  end

  defp validate_files(request, project, opts) do
    intent_path = intent_path(request.slug)
    acceptance_path = acceptance_path(request.slug)

    with {:ok, intent_bytes} <- read_generated(request.workdir, intent_path),
         {:ok, intent} <- parse_intent(intent_bytes, intent_path),
         :ok <- clean_intent(intent),
         {:ok, test_bytes} <- read_generated(request.workdir, acceptance_path) do
      Kogen.Checks.validate_shape(%ShapeValidation{
        workdir: request.workdir,
        project: project,
        intent: intent,
        acceptance_bytes: test_bytes,
        run_dir: opts.run_dir,
        env: opts.env,
        git_env: request.git_env
      })
    end
  end

  defp parse_intent(bytes, path) do
    case IntentDomain.parse_binary(bytes, path) do
      {:ok, %Intent{} = intent} ->
        {:ok, intent}

      {:error, issues} ->
        {:error, failure(:candidate, :intent_parse_failed, render_issues("parse", issues))}
    end
  end

  defp clean_intent(%Intent{} = intent) do
    case IntentDomain.lint(intent) do
      [] -> :ok
      issues -> {:error, failure(:candidate, :intent_lint_failed, render_issues("lint", issues))}
    end
  end

  defp read_generated(workdir, relative) do
    case File.read(Path.join(workdir, relative)) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         failure(
           :candidate,
           :generated_file_missing,
           "Cannot read #{relative}: #{inspect(reason)}"
         )}
    end
  end

  defp harness_options(request, %Project{} = project) do
    opts = %Opts{
      workdir: request.workdir,
      run_dir: request.run_dir,
      project: project,
      provider_mod: request.provider_mod,
      provider_config: request.provider_config,
      proc_mod: Proc,
      env: Map.merge(request.env, project.env),
      models: %{builder: {request.model, request.effort}, strong: {request.model, request.effort}},
      limits: %{max_turns: @max_turns, wall_ms: @wall_ms}
    }

    {:ok, opts}
  end

  defp valid_request(%Request{} = request) do
    cond do
      not absolute_directory?(request.workdir) ->
        {:error, :project_unavailable}

      not valid_slug?(request.slug) ->
        {:error, :invalid_slug}

      not is_binary(request.task) or String.trim(request.task) == "" ->
        {:error, :empty_task}

      not nonempty_string?(request.model) or not nonempty_string?(request.effort) ->
        {:error, :invalid_model}

      not is_binary(request.run_dir) or Path.type(request.run_dir) != :absolute ->
        {:error, :invalid_run_dir}

      not is_map(request.env) or not is_map(request.git_env) ->
        {:error, :invalid_environment}

      true ->
        :ok
    end
  end

  defp result(request, calls, rounds, opts) do
    %Result{
      slug: request.slug,
      intent_path: Path.join(request.workdir, intent_path(request.slug)),
      acceptance_path: Path.join(request.workdir, acceptance_path(request.slug)),
      calls: calls,
      rounds: rounds,
      transcript_path: Path.join(opts.run_dir, "transcript.jsonl")
    }
  end

  defp validation_exhausted(%Failure{} = failure, repairs) do
    {:error,
     %Failure{
       class: :candidate,
       reason: :shaping_validation_failed,
       detail:
         "Shaper validation failed after #{repairs} repair round(s).\n" <> failure_output(failure)
     }}
  end

  defp failure_output(%Failure{} = failure),
    do: "#{failure.class}/#{failure.reason}: #{failure.detail}"

  defp render_issues(kind, issues) do
    Enum.map_join(issues, "", fn issue ->
      line = if Map.get(issue, :line), do: " at #{issue.line}", else: ""
      "#{kind}#{line}: #{issue.message}\n"
    end)
  end

  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp acceptance_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"
  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
