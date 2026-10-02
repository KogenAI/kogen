defmodule Kogen.Kernel.Build.StageRunner do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProviderError
  alias Kogen.Harness
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Result, as: HarnessResult
  alias Kogen.Kernel.Build.Commit
  alias Kogen.Kernel.Build.Guard
  alias Kogen.Kernel.Build.Reviewer
  alias Kogen.Kernel.Build.Session
  alias Kogen.Provider.ChatGPT
  alias Kogen.State
  alias Kogen.Workspace

  @spec run(atom(), map(), Session.t()) ::
          {:ok, Session.t(), [term()]}
          | {:error, Session.t(), Failure.t()}
          | {:base_moved, Session.t()}
  def run(:context, _args, session), do: context(session)
  def run(:plan, _args, session), do: plan(session)
  def run(:develop, args, session), do: develop(args, session)
  def run(:fix, _args, session), do: fix(session)
  def run(:check, _args, session), do: checks(session)
  def run(:review, _args, session), do: Reviewer.run(session)
  def run(:commit, _args, session), do: Commit.run(session)
  def run(:land, args, session), do: Commit.land(args, session)

  @spec harness_options(Session.t()) :: Opts.t()
  def harness_options(session), do: harness_opts(session)

  defp context(session) do
    case guard(session) do
      :ok -> context_after_guard(session)
      {:error, %Failure{} = failure} -> fail(session, :context, failure)
    end
  end

  defp context_after_guard(session) do
    with :ok <- red_on_base(session),
         {:ok, pack} <- Harness.context_pack(harness_opts(session), session.intent_text),
         :ok <- record_model(session, :context, "gpt-6-luna", "low", pack.usage) do
      {:ok, %{session | pack: pack, failure: nil, failure_text: nil},
       [{:stage_ok, :context, %{}}]}
    else
      {:error, %Failure{} = failure} ->
        fail(session, :context, base_check_failure(failure))

      {:error, %ProviderError{} = error} ->
        fail(session, :context, provider_failure(error))

      {:error, reason} ->
        fail(session, :context, harness_failure(reason))
    end
  end

  defp red_on_base(session) do
    case Kogen.Checks.red_on_base(
           session.workdir,
           session.intent,
           session.run_dir,
           session.process_env,
           session.git_env
         ) do
      :ok -> :ok
      {:error, %Failure{} = failure} -> {:error, failure}
    end
  end

  defp plan(%Session{pack: pack} = session) do
    case Harness.plan(harness_opts(session), pack, session.intent_text) do
      {:ok, plan} ->
        case record_model(
               session,
               :plan,
               session.request.model,
               session.request.effort,
               plan.usage
             ) do
          :ok ->
            {:ok, %{session | plan: plan, failure: nil, failure_text: nil},
             [{:stage_ok, :plan, %{}}]}

          {:error, reason} ->
            fail(session, :plan, controller_failure(:state_write_failed, inspect(reason)))
        end

      {:error, %ProviderError{} = error} ->
        fail(session, :plan, provider_failure(error))

      {:error, reason} ->
        fail(session, :plan, harness_failure(reason))
    end
  end

  defp develop(_args, %Session{} = session) do
    resume = resume_data(session)

    case Harness.develop(harness_opts(session), session.intent_text, session.plan, resume, 0) do
      {:ok, %HarnessResult{} = result} ->
        finish_develop(session, result)

      {:error, %ProviderError{} = error} ->
        fail(session, :develop, provider_failure(error))

      {:error, %Failure{} = failure} ->
        fail(session, :develop, failure)

      {:error, reason} ->
        fail(session, :develop, harness_failure(reason))
    end
  end

  defp finish_develop(session, result) do
    with {:ok, tree} <- Workspace.tree_hash(session.workdir, session.git_env),
         :ok <-
           record_model(
             session,
             :develop,
             session.request.model,
             session.request.effort,
             result.usage
           ) do
      {failure, detail} = gate_failure(result)
      session = %{session | last_harness: result, failure: failure, failure_text: detail}

      events = [
        {:stage_ok, :develop, %{tree: tree}},
        {:stage_ok, :done_gate, %{outcome: result.outcome}}
      ]

      {:ok, session, events}
    else
      {:error, reason} ->
        fail(session, :develop, controller_failure(:workspace_failed, inspect(reason)))
    end
  end

  defp gate_failure(%HarnessResult{outcome: :done}), do: {nil, nil}

  defp gate_failure(%HarnessResult{outcome: :gave_up}),
    do:
      {candidate_failure(:developer_gave_up, "Developer exhausted its turn or wall limit."),
       "Developer exhausted its turn or wall limit."}

  defp gate_failure(%HarnessResult{outcome: :gate_red, gate: gate}) do
    details = gate_failures(gate)
    detail = if details == [], do: "Harness done gate failed.", else: Enum.join(details, "\n")
    {candidate_failure(:done_gate_red, detail), detail}
  end

  defp gate_failures(%{failures: failures}) when is_list(failures), do: failures
  defp gate_failures(_gate), do: []

  defp resume_data(%Session{last_harness: %HarnessResult{items: items}, failure_text: text})
       when is_binary(text), do: %{previous_items: items, failure_text: text}

  defp resume_data(_session), do: nil

  defp fix(session) do
    with :ok <-
           Guard.check(
             session.workdir,
             session.base_sha,
             session.intent,
             session.project,
             manifest(session),
             session.git_env
           ),
         {:ok, _results} <-
           Kogen.Checks.fix(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env
           ),
         :ok <- record(session, %{event: :fix_result, status: :pass}) do
      {:ok, %{session | failure: nil, failure_text: nil}, [{:stage_ok, :fix, %{}}]}
    else
      {:error, %Failure{} = failure} -> fail(session, :fix, failure)
      {:error, reason} -> fail(session, :fix, controller_failure(:fix_failed, inspect(reason)))
    end
  end

  defp checks(session) do
    with :ok <-
           Guard.check(
             session.workdir,
             session.base_sha,
             session.intent,
             session.project,
             manifest(session),
             session.git_env
           ),
         {:ok, check_result} <-
           Kogen.Checks.run_all(
             session.workdir,
             session.project,
             session.run_dir,
             session.process_env,
             session.git_env
           ) do
      finish_checks(session, check_result)
    else
      {:error, %Failure{} = failure} ->
        fail(session, :check, failure)
    end
  end

  defp finish_checks(session, check_result) do
    with {:ok, acceptance} <-
           Kogen.Checks.acceptance(
             session.workdir,
             session.intent,
             session.run_dir,
             session.process_env,
             session.git_env
           ),
         :ok <- record_check_results(session, check_result, acceptance),
         :ok <- check_passed(check_result, acceptance) do
      {:ok,
       %{
         session
         | acceptance: acceptance.ledger,
           receipts: check_result.receipts,
           failure: nil,
           failure_text: nil
       }, [{:stage_ok, :check, %{status: :pass}}]}
    else
      {:error, %Failure{} = failure} ->
        fail(session, :check, failure)

      {:error, reason} ->
        fail(session, :check, controller_failure(:checks_failed, inspect(reason)))
    end
  end

  defp check_passed(%{status: :pass}, %{status: :pass}), do: :ok

  defp check_passed(check_result, acceptance_result) do
    detail =
      "checks=#{inspect(check_result.status)} acceptance=#{inspect(acceptance_result.status)}"

    {:error, candidate_failure(:verification_failed, detail)}
  end

  defp record_check_results(session, check_result, acceptance_result) do
    with :ok <-
           record(session, %{
             event: :check_result,
             status: check_result.status,
             receipts: check_result.receipts
           }) do
      record(session, %{
        event: :acceptance_result,
        status: acceptance_status(acceptance_result.status),
        ledger: acceptance_result.ledger
      })
    end
  end

  defp acceptance_status(:pass), do: :pass
  defp acceptance_status({:fail, ids}), do: %{status: :fail, failed_ids: ids}

  defp harness_opts(session) do
    guard = fn ->
      Guard.check(
        session.workdir,
        session.base_sha,
        session.intent,
        session.project,
        manifest(session),
        session.git_env
      )
    end

    session.harness_opts ||
      %Opts{
        workdir: session.workdir,
        run_dir: session.run_dir,
        project: session.project,
        provider_mod: ChatGPT,
        provider_config: session.request.provider_config,
        proc_mod: Kogen.Proc,
        env: session.process_env,
        before_gate: guard,
        models: %{
          builder: {session.request.model, session.request.effort},
          strong: {session.request.model, session.request.effort}
        },
        limits: %{max_turns: 60, wall_ms: 1_800_000},
        repairs_left: 0
      }
  end

  defp manifest(session), do: session.approval.protected_manifest

  defp guard(session) do
    Guard.check(
      session.workdir,
      session.base_sha,
      session.intent,
      session.project,
      manifest(session),
      session.git_env
    )
  end

  defp record_model(session, stage, model, effort, usage) do
    record(session, %{
      event: :model_stage,
      stage: stage,
      model: model,
      effort: effort,
      tokens: usage
    })
  end

  defp record(session, event), do: State.record(session.run, event)

  defp fail(session, stage, %Failure{} = failure) do
    event = %{
      event: :stage_failure,
      stage: stage,
      class: failure.class,
      reason: failure.reason,
      detail: failure.detail
    }

    case record(session, event) do
      :ok ->
        {:error, %{session | failure: failure, failure_text: failure.detail}, failure}

      {:error, reason} ->
        controller = controller_failure(:state_write_failed, inspect(reason))
        {:error, %{session | failure: controller, failure_text: controller.detail}, controller}
    end
  end

  defp base_check_failure(%Failure{} = failure) do
    %Failure{class: :environment, reason: :base_acceptance_failed, detail: failure.detail}
  end

  defp provider_failure(%ProviderError{class: :login} = error),
    do: %Failure{class: :environment, reason: :login, detail: error.message}

  defp provider_failure(%ProviderError{} = error),
    do: %Failure{class: :provider, reason: error.class, detail: error.message}

  defp harness_failure(%{reason: reason, detail: detail})
       when is_atom(reason) and is_binary(detail) do
    class =
      if reason in [:command_missing, :process_failed, :log_directory_failed],
        do: :environment,
        else: :controller

    %Failure{class: class, reason: reason, detail: detail}
  end

  defp harness_failure(reason), do: controller_failure(:harness_failed, inspect(reason))

  defp candidate_failure(reason, detail),
    do: %Failure{class: :candidate, reason: reason, detail: detail}

  defp controller_failure(reason, detail),
    do: %Failure{class: :controller, reason: reason, detail: detail}
end
