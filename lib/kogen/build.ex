defmodule Kogen.Build do
  @moduledoc """
  The synchronous Build loop: preconditions, one Developer launch, Stop-hook
  Check settlement, declared-target verification, a fresh Review, bounded
  Rework (at most `outer_resumptions` resumes of the exact Developer
  thread), and one ordinary Git Commit carrying the Intent identity.
  """
  use Boundary,
    deps: [Kogen.Intent, Kogen.Harness, Kogen.Check, Kogen.Git, Kogen.VerificationPolicy]

  @lock_path ".kogen/build.lock"
  @approved_base ".kogen/intents/approved"
  @complete_base ".kogen/intents/complete"

  @spec run(String.t()) :: :ok | {:error, String.t()}
  def run(slug) do
    with {:ok, intent} <- Kogen.Intent.read(slug, @approved_base),
         {:ok, approved_entries} <- read_approved_entries(slug),
         :ok <- check_clean_worktree(),
         :ok <- check_branch_attached(),
         :ok <- check_complete_absent(slug) do
      case acquire_lock() do
        :ok ->
          try do
            with :ok <- check_make_check_target() do
              do_build(slug, intent, approved_entries)
            end
          after
            release_lock()
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Approved inputs are ignored by Git. Keep their actual entries and bytes
  # in this Build's memory so provider/check edits cannot become approval.
  defp read_approved_entries(slug) do
    {:ok, package_entries(Path.join(@approved_base, slug), "")}
  rescue
    error in File.Error ->
      {:error, "could not read Approved Intent: #{Exception.message(error)}"}
  end

  defp package_entries(root, relative) do
    path = Path.join(root, relative)
    stat = File.lstat!(path)

    case stat.type do
      :directory ->
        children = path |> File.ls!() |> Enum.sort()

        [
          {relative, :directory, stat.mode}
          | Enum.flat_map(children, &package_entries(root, Path.join(relative, &1)))
        ]

      :regular ->
        [{relative, :regular, stat.mode, File.read!(path)}]

      :symlink ->
        raise File.Error,
          reason: :einval,
          action: "read Approved Intent symlink (unsupported)",
          path: path

      _ ->
        raise File.Error, reason: :einval, action: "read Approved entry", path: path
    end
  end

  defp approved_unchanged(ctx) do
    case read_approved_entries(ctx.slug) do
      {:ok, entries} when entries == ctx.approved_entries -> :ok
      _ -> {:error, "Approved Intent changed during Build; stopped without publication"}
    end
  end

  defp check_complete_absent(slug) do
    path = Path.join(@complete_base, slug)

    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        {:error, "Complete Intent already exists: #{slug}"}

      {:error, reason} ->
        {:error, "could not inspect Complete Intent #{slug}: #{inspect(reason)}"}
    end
  end

  defp check_clean_worktree do
    if Kogen.Git.clean_worktree?() do
      :ok
    else
      {:error, "worktree is not clean (git status --porcelain is non-empty)"}
    end
  end

  defp check_branch_attached do
    case Kogen.Git.current_branch() do
      {:ok, _branch} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_lock do
    case File.open(@lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)
        :ok

      {:error, :eexist} ->
        {:error, "build lock already present: #{@lock_path}"}

      {:error, reason} ->
        {:error, "could not acquire build lock: #{inspect(reason)}"}
    end
  end

  defp release_lock do
    File.rm(@lock_path)
    :ok
  end

  defp check_make_check_target do
    if MapSet.member?(Kogen.Check.declared_targets("Makefile"), "check") do
      :ok
    else
      {:error, "Makefile has no check target"}
    end
  end

  # The static, unchanging-for-the-whole-Build inputs, bundled so the
  # settle/review/rework chain below stays under a sane arity as it
  # threads per-attempt state (candidate id, session id, resumption count,
  # Check record, target results) through the loop.
  defp do_build(slug, intent, approved_entries) do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, scenarios_text, targets} <- load_scenarios(slug),
         :ok <- Kogen.Check.validate_targets(targets),
         :ok <- Kogen.VerificationPolicy.preflight(targets),
         :ok <- Kogen.Check.invalidate!() do
      developer_prompt = render_developer_prompt(intent, scenarios_text, targets, config)

      ctx = %{
        slug: slug,
        intent: intent,
        config: config,
        targets: targets,
        policy_environment: Kogen.VerificationPolicy.environment(targets),
        approved_entries: approved_entries
      }

      launch(ctx, developer_prompt)
    end
  end

  defp launch(ctx, developer_prompt) do
    with :ok <- approved_unchanged(ctx),
         :ok <- Kogen.VerificationPolicy.preflight(ctx.targets) do
      case Kogen.Harness.launch_developer(
             developer_prompt,
             ctx.config.developer.model,
             ctx.config.developer.effort,
             ctx.policy_environment
           ) do
        {:ok, %{session_id: session_id, result: dev_result}} ->
          settle(ctx, session_id, 0, dev_result)

        {:error, reason} ->
          {:error, "harness failure launching Developer: #{inspect(reason)}"}
      end
    end
  end

  defp load_scenarios(slug) do
    path = Path.join([@approved_base, slug, "scenarios.yaml"])

    with {:ok, text} <- File.read(path),
         {:ok, list} <- YamlElixir.read_from_string(text),
         true <- is_list(list) and list != [],
         true <- Enum.all?(list, &executable_scenario?/1) do
      targets = list |> Enum.flat_map(& &1["verified_by"]) |> Enum.uniq()
      {:ok, text, targets}
    else
      _ -> {:error, "scenarios.yaml missing or invalid: #{path}"}
    end
  end

  defp executable_scenario?(%{"verified_by" => targets}),
    do: is_list(targets) and targets != []

  defp executable_scenario?(_scenario), do: false

  defp settle(ctx, session_id, resumptions_used, dev_result) do
    with :ok <- approved_unchanged(ctx),
         {:ok, candidate_id} <- Kogen.Git.candidate_id() do
      if Kogen.Check.settled_pass?(candidate_id, session_id) do
        {:ok, check_record} = Kogen.Check.read_record()
        after_check(ctx, candidate_id, session_id, resumptions_used, check_record, dev_result)
      else
        reason = Kogen.Check.settlement_failure_reason(candidate_id, session_id)
        rework(ctx, session_id, resumptions_used, "settled Check failure: #{reason}")
      end
    end
  end

  defp after_check(ctx, candidate_id, session_id, resumptions_used, check_record, dev_result) do
    case run_declared_targets(ctx.targets) do
      {:ok, target_results} ->
        case Kogen.Git.candidate_id() do
          {:ok, ^candidate_id} ->
            review(
              ctx,
              candidate_id,
              session_id,
              resumptions_used,
              check_record,
              target_results,
              dev_result
            )

          {:ok, other} ->
            {:error,
             "Candidate mutated during declared-target verification (#{candidate_id} -> #{other})"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        rework(ctx, session_id, resumptions_used, "declared-target failure: #{reason}")
    end
  end

  # Collects the actual output of every declared target beyond `check` (not
  # merely its name), so Complete evidence can bind the real Check result
  # to the Candidate instead of a bare list of passing target names.
  defp run_declared_targets(targets) do
    targets
    |> Enum.reject(&(&1 == "check"))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Kogen.Check.run_target(name) do
        {:ok, out} ->
          {:cont, {:ok, [{name, tail_of(out, 2000)} | acc]}}

        {:error, {code, out}} ->
          {:halt, {:error, "make #{name} exited #{code}: #{tail_of(out, 800)}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp review(
         ctx,
         candidate_id,
         session_id,
         resumptions_used,
         check_record,
         target_results,
         dev_result
       ) do
    with :ok <- approved_unchanged(ctx) do
      do_review(
        ctx,
        candidate_id,
        session_id,
        resumptions_used,
        check_record,
        target_results,
        dev_result
      )
    end
  end

  defp do_review(
         ctx,
         candidate_id,
         session_id,
         resumptions_used,
         check_record,
         target_results,
         dev_result
       ) do
    prompt = render_reviewer_prompt(ctx.intent, candidate_id, ctx.config)

    case Kogen.Harness.launch_reviewer(
           prompt,
           ctx.config.reviewer.model,
           ctx.config.reviewer.effort
         ) do
      {:ok, %{session_id: ^session_id}} ->
        {:error, "Reviewer session must differ from the Developer session"}

      {:ok, %{verdict: "accept"} = verdict} ->
        with_unmutated_candidate(ctx, candidate_id, fn ->
          accept(
            ctx,
            candidate_id,
            session_id,
            verdict,
            resumptions_used,
            check_record,
            target_results,
            dev_result
          )
        end)

      {:ok, %{verdict: "rework", findings: findings}} ->
        with_unmutated_candidate(ctx, candidate_id, fn ->
          reason = "Reviewer findings: " <> Enum.join(findings, "; ")
          rework(ctx, session_id, resumptions_used, reason)
        end)

      {:error, reason} ->
        {:error, "Reviewer failure: #{inspect(reason)}"}
    end
  end

  defp with_unmutated_candidate(ctx, candidate_id, fun) do
    with :ok <- approved_unchanged(ctx) do
      case Kogen.Git.candidate_id() do
        {:ok, ^candidate_id} -> fun.()
        {:ok, other} -> {:error, "Candidate mutated during Review (#{candidate_id} -> #{other})"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp rework(ctx, session_id, resumptions_used, reason) do
    with :ok <- approved_unchanged(ctx) do
      resume(ctx, session_id, resumptions_used, reason)
    end
  end

  defp resume(ctx, session_id, resumptions_used, reason) do
    max = ctx.config.outer_resumptions

    if resumptions_used >= max do
      {:error, "stopped after #{max} outer resumptions without an accepting Review: #{reason}"}
    else
      with :ok <- Kogen.VerificationPolicy.preflight(ctx.targets),
           :ok <- Kogen.Check.invalidate!() do
        resume_developer_turn(ctx, session_id, resumptions_used, reason)
      end
    end
  end

  defp resume_developer_turn(ctx, session_id, resumptions_used, reason) do
    case Kogen.Harness.resume_developer(
           session_id,
           resume_feedback(ctx, reason),
           ctx.config.developer.model,
           ctx.config.developer.effort,
           ctx.policy_environment
         ) do
      {:ok, %{session_id: ^session_id, result: dev_result}} ->
        settle(ctx, session_id, resumptions_used + 1, dev_result)

      {:ok, %{session_id: other}} ->
        {:error, "resume created a new session (expected #{session_id}, got #{other})"}

      {:error, harness_reason} ->
        {:error, "harness failure during resume: #{inspect(harness_reason)}"}
    end
  end

  # Filesystem mutations happen before the Commit (the Commit itself must
  # observe the final desired tree: complete/<slug>/ present, approved/
  # <slug>/ gone). If `Kogen.Git.commit/3` then fails, we restore the
  # Approved Intent from the copy already sitting in `complete_dir` (minus
  # the evidence file we added), delete `complete_dir`, and unstage the
  # index `git add -A` touched — the smallest change that leaves the
  # worktree exactly as it was before this attempt, so a retried Build
  # sees its Approved input intact and no uncommitted Complete is ever
  # left behind looking like a done deal. This is ordinary restoration
  # from data we already have on disk, not a general recovery engine.
  defp accept(
         ctx,
         candidate_id,
         session_id,
         verdict,
         resumptions_used,
         check_record,
         target_results,
         dev_result
       ) do
    with :ok <- approved_unchanged(ctx),
         :ok <- check_complete_absent(ctx.slug) do
      do_accept(
        ctx,
        candidate_id,
        session_id,
        verdict,
        resumptions_used,
        check_record,
        target_results,
        dev_result
      )
    end
  end

  defp do_accept(
         ctx,
         candidate_id,
         session_id,
         verdict,
         resumptions_used,
         check_record,
         target_results,
         dev_result
       ) do
    %{slug: slug, intent: intent} = ctx
    complete_dir = Path.join(@complete_base, slug)
    approved_dir = Path.join(@approved_base, slug)

    File.mkdir_p!(Path.dirname(complete_dir))
    File.cp_r!(approved_dir, complete_dir)

    evidence =
      evidence_markdown(
        intent,
        candidate_id,
        session_id,
        verdict,
        resumptions_used,
        check_record,
        target_results,
        dev_result
      )

    evidence_name = available_evidence_name(complete_dir)
    File.write!(Path.join(complete_dir, evidence_name), evidence)
    File.rm_rf!(approved_dir)

    trailers = [{"Kogen-Intent-ID", intent.id}, {"Kogen-Intent", slug}]

    allowed_paths = [complete_dir <> "/", approved_dir <> "/"]

    case Kogen.Git.stage_and_verify_candidate(candidate_id, allowed_paths) do
      :ok ->
        case Kogen.Git.commit_staged(intent.title, trailers) do
          {:ok, _head} ->
            verify_committed_candidate(candidate_id, allowed_paths)

          {:error, reason} ->
            restore_approved_after_failed_commit(approved_dir, complete_dir, evidence_name)
            {:error, "commit failed, Approved Intent restored, no Commit made: #{reason}"}
        end

      {:error, reason} ->
        restore_approved_after_failed_commit(approved_dir, complete_dir, evidence_name)

        {:error,
         "final staged tree did not match Candidate, Approved Intent restored: #{inspect(reason)}"}
    end
  end

  defp verify_committed_candidate(candidate_id, allowed_paths) do
    case Kogen.Git.assert_commit_diff_only(candidate_id, allowed_paths) do
      :ok -> :ok
      {:error, reason} -> {:error, "post-commit diff assertion failed: #{inspect(reason)}"}
    end
  end

  defp restore_approved_after_failed_commit(approved_dir, complete_dir, evidence_name) do
    File.rm_rf!(approved_dir)
    File.cp_r!(complete_dir, approved_dir)
    File.rm!(Path.join(approved_dir, evidence_name))
    File.rm_rf!(complete_dir)
    Kogen.Git.unstage_all()
  end

  defp available_evidence_name(dir) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = if index == 0, do: "evidence.md", else: "build-evidence-#{index}.md"
      if not File.exists?(Path.join(dir, name)), do: name
    end)
  end

  defp evidence_markdown(
         intent,
         candidate_id,
         developer_session_id,
         verdict,
         resumptions_used,
         check_record,
         target_results,
         _dev_result
       ) do
    findings_text =
      case verdict.findings do
        [] -> "(none)"
        findings -> Enum.join(findings, "; ")
      end

    verdict_json = Jason.encode!(%{"verdict" => verdict.verdict, "findings" => verdict.findings})

    check_section = """
    ## Check (Stop hook Verification Record, bound to this Candidate)

    - status: `#{Map.get(check_record, "status")}`
    - exit_code: `#{Map.get(check_record, "exit_code")}`
    - finished_at: `#{Map.get(check_record, "finished_at")}`
    - session_id: `#{Map.get(check_record, "session_id")}`
    - output tail:
      ```
      #{Map.get(check_record, "reason")}
      ```
    """

    targets_section =
      case target_results do
        [] ->
          "## Declared targets\n\n(none beyond `check`)\n"

        results ->
          bodies =
            Enum.map_join(results, "\n", fn {name, out} ->
              """
              ### `make #{name}`

              ```
              #{out}
              ```
              """
            end)

          "## Declared targets (beyond `check`)\n\n" <> bodies
      end

    """
    # Complete evidence: #{intent.title}

    - Candidate id: `#{candidate_id}`
    - Developer session id: `#{developer_session_id}`
    - Reviewer session id: `#{verdict.session_id}`
    - Outer resumptions used: #{resumptions_used}
    #{check_section}
    #{targets_section}
    ## Reviewer Verdict (structured, schema-valid)

    ```json
    #{verdict_json}
    ```

    - Reviewer verdict: #{verdict.verdict}
    - Reviewer findings: #{findings_text}
    """
  end

  defp render_developer_prompt(intent, scenarios_text, targets, config) do
    intent_yaml = File.read!(Path.join([@approved_base, intent.slug, "intent.yaml"]))

    "priv/kogen/prompts/developer.md"
    |> File.read!()
    |> String.replace("{{intent_title}}", intent.title)
    |> String.replace("{{intent_id}}", intent.id)
    |> String.replace("{{approved_path}}", Path.join(@approved_base, intent.slug))
    |> String.replace("{{intent_yaml}}", intent_yaml)
    |> String.replace("{{scenarios_yaml}}", scenarios_text)
    |> String.replace(
      "{{may_change_guarded_paths}}",
      Enum.join(intent.may_change_guarded_paths, ", ")
    )
    |> String.replace(
      "{{verification_ownership}}",
      Kogen.VerificationPolicy.developer_instruction(targets)
    )
    |> render_helper_profiles(config)
  end

  defp resume_feedback(ctx, reason) do
    "#{reason}\n\n#{Kogen.VerificationPolicy.developer_instruction(ctx.targets)}"
  end

  defp render_reviewer_prompt(intent, candidate_id, config) do
    "priv/kogen/prompts/reviewer.md"
    |> File.read!()
    |> String.replace("{{intent_title}}", intent.title)
    |> String.replace("{{intent_id}}", intent.id)
    |> String.replace("{{approved_path}}", Path.join(@approved_base, intent.slug))
    |> String.replace("{{candidate_id}}", candidate_id)
    |> render_helper_profiles(config)
  end

  defp render_helper_profiles(prompt, config) do
    prompt
    |> String.replace("{{scout_model}}", config.helpers.scout.model)
    |> String.replace("{{scout_effort}}", config.helpers.scout.effort)
    |> String.replace("{{worker_model}}", config.helpers.worker.model)
    |> String.replace("{{worker_effort}}", config.helpers.worker.effort)
    |> String.replace("{{expert_model}}", config.helpers.expert.model)
    |> String.replace("{{expert_effort}}", config.helpers.expert.effort)
  end

  defp tail_of(str, n) do
    len = byte_size(str)
    if len <= n, do: str, else: binary_part(str, len - n, n)
  end
end
