defmodule Kogen.Build do
  @moduledoc """
  The synchronous Build loop: preconditions, one Developer launch, Stop-hook
  Check settlement, declared-target verification, a fresh Review, bounded
  Rework (at most `outer_resumptions` resumes of the exact Developer
  thread), and one ordinary Git Commit carrying the Intent identity.
  """
  use Boundary,
    deps: [
      Kogen.Intent,
      Kogen.Harness,
      Kogen.Check,
      Kogen.Git,
      Kogen.VerificationPolicy,
      Kogen.ExecutionPolicy
    ]

  alias Kogen.Build.{Contract, Tracking}

  @lock_path ".kogen/build.lock"
  @approved_base ".kogen/intents/approved"
  @complete_base ".kogen/intents/complete"

  @spec run(String.t()) :: :ok | {:error, String.t()}
  def run(slug) do
    with {:ok, intent} <- Kogen.Intent.read(slug, @approved_base),
         {:ok, approved_entries} <- read_approved_entries(slug),
         :ok <- Kogen.Git.reject_candidate_blinding_index_flags(),
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
         {:ok, contract} <- Contract.load(Path.join(@approved_base, slug)),
         :ok <- Kogen.VerificationPolicy.preflight(contract.targets),
         {:ok, tracking} <- Tracking.new(intent, contract, approved_entries) do
      ctx = %{
        slug: slug,
        intent: intent,
        config: config,
        contract: contract,
        targets: contract.targets,
        policy_environment: Kogen.VerificationPolicy.environment(contract.targets),
        approved_entries: approved_entries,
        tracking: tracking,
        token: nil,
        reviewers: [],
        references: %{}
      }

      begin_attempt(ctx, nil, 0, nil)
    end
  end

  defp begin_attempt(ctx, session_id, number, reason) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    attempt = %{
      "attempt_token" => token,
      "number" => number,
      "status" => "pending",
      "developer_session_id" => session_id
    }

    record = ctx.tracking.record

    record =
      record
      |> Map.put("attempts", record["attempts"] ++ [attempt])
      |> Map.put("status", "pending")

    case Tracking.update(ctx.tracking, record) do
      {:ok, tracking} ->
        ctx = %{ctx | tracking: tracking, token: token, references: %{}}
        launch_attempt(ctx, session_id, number, reason)

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  defp launch_attempt(ctx, session_id, number, reason) do
    with :ok <- inputs_unchanged(ctx),
         :ok <- Kogen.VerificationPolicy.preflight(ctx.targets),
         :ok <- Kogen.Check.invalidate!() do
      prompt = developer_prompt(ctx, reason)

      result =
        if session_id do
          Kogen.Harness.resume_developer(
            session_id,
            prompt,
            ctx.config.developer.model,
            ctx.config.developer.effort,
            ctx.policy_environment
          )
        else
          Kogen.Harness.launch_developer(
            prompt,
            ctx.config.developer.model,
            ctx.config.developer.effort,
            ctx.policy_environment
          )
        end

      receive_developer(ctx, session_id, number, result)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp receive_developer(ctx, expected, number, {:ok, turn}) do
    if expected && turn.session_id != expected do
      stop(ctx, "resume created a new session (expected #{expected}, got #{turn.session_id})")
    else
      settle(ctx, turn.session_id, number, Map.get(turn, :message, ""))
    end
  end

  defp receive_developer(ctx, _expected, _number, {:error, reason}),
    do: stop(ctx, "harness failure during Developer turn: #{inspect(reason)}")

  defp settle(ctx, session_id, number, message) do
    # No controller update happens during the Developer turn. Preserve that
    # exact version before recording settlement or the parsed handoff.
    developer_tracking = ctx.tracking

    with :ok <- inputs_unchanged(ctx),
         {:ok, candidate_id} <- Kogen.Git.candidate_id(),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "candidate_id" => candidate_id,
             "developer_session_id" => session_id,
             "developer_message" => message,
             "check" => read_check(),
             "check_bytes" => read_optional(Kogen.Check.record_path()),
             "check_history" => read_optional(Kogen.Check.history_path())
           }) do
      if Kogen.Check.settled_pass?(candidate_id, session_id) do
        validate_handoff(ctx, candidate_id, session_id, number, message, developer_tracking)
      else
        reason = Kogen.Check.settlement_failure_reason(candidate_id, session_id)
        rework(ctx, session_id, number, "settled Check failure: #{reason}")
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp validate_handoff(ctx, candidate_id, session_id, number, message, developer_tracking) do
    case Contract.handoff(message, ctx.contract, ctx.token, Tracking.open_findings(ctx.tracking)) do
      {:ok, handoff} ->
        with {:ok, references} <- snapshot_references(handoff, developer_tracking),
             {:ok, ctx} <-
               record_attempt(ctx, %{
                 "handoff" => handoff,
                 "developer_reference_snapshots" => references
               }) do
          ctx = %{ctx | references: references}
          after_check(ctx, candidate_id, session_id, number)
        else
          {:error, reason} -> stop(ctx, reason)
        end

      {:error, reason} ->
        rework(ctx, session_id, number, "Developer handoff invalid: #{reason}")
    end
  end

  defp after_check(ctx, candidate_id, session_id, number) do
    case bound_inputs_unchanged(ctx, candidate_id, session_id) do
      :ok ->
        run_declared_targets(
          ctx,
          candidate_id,
          session_id,
          number,
          Enum.reject(ctx.targets, &(&1 == "check"))
        )

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  defp run_declared_targets(ctx, candidate_id, session_id, number, []) do
    review(ctx, candidate_id, session_id, number)
  end

  defp run_declared_targets(ctx, candidate_id, session_id, number, [name | rest]) do
    outcome = Kogen.Check.run_target(name)
    receipt = target_receipt(name, outcome, candidate_id, session_id, ctx.token)
    receipts = Map.get(current_attempt(ctx), "targets", []) ++ [receipt]

    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <- record_attempt(ctx, %{"targets" => receipts}) do
      case outcome do
        {:ok, _out} ->
          run_declared_targets(ctx, candidate_id, session_id, number, rest)

        {:error, {code, out}} ->
          rework(
            ctx,
            session_id,
            number,
            "declared-target failure: make #{name} exited #{code}: #{tail_of(out, 800)}"
          )
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp target_receipt(name, result, candidate_id, session_id, token) do
    {status, code, output} =
      case result do
        {:ok, out} -> {"passed", 0, out}
        {:error, {code, out}} -> {"failed", code, out}
      end

    %{
      "target" => name,
      "status" => status,
      "exit_code" => code,
      "output" => tail_of(output, 4000),
      "candidate_id" => candidate_id,
      "developer_session_id" => session_id,
      "attempt_token" => token
    }
  end

  defp review(ctx, candidate_id, session_id, number) do
    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "scenario_receipts" => scenario_receipts(ctx),
             "reference_snapshots" => ctx.references
           }) do
      prompt =
        render_reviewer_prompt(ctx.intent, candidate_id, ctx.config) <>
          tracking_context(ctx, candidate_id)

      result =
        Kogen.Harness.launch_reviewer(
          prompt,
          ctx.config.reviewer.model,
          ctx.config.reviewer.effort
        )

      receive_review(ctx, candidate_id, session_id, number, result)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp receive_review(ctx, candidate_id, session_id, number, {:ok, verdict}) do
    binding = %{candidate_id: candidate_id, attempt_token: ctx.token}

    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         :ok <- fresh_reviewer(ctx, verdict.session_id, session_id),
         {:ok, response} <-
           Contract.verdict(
             verdict.response,
             ctx.contract,
             binding,
             Tracking.open_findings(ctx.tracking)
           ),
         {:ok, references} <- snapshot_references(response, ctx.tracking),
         :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, tracking} <-
           Tracking.apply_verdict(
             ctx.tracking,
             response,
             verdict.session_id,
             references
           ) do
      ctx = %{
        ctx
        | tracking: tracking,
          reviewers: ctx.reviewers ++ [verdict.session_id],
          references: Map.merge(ctx.references, references)
      }

      if response["verdict"] == "accept" do
        publish(ctx, candidate_id, session_id, verdict, number)
      else
        rework(ctx, session_id, number, "Reviewer findings: " <> Jason.encode!(response))
      end
    else
      {:error, reason} ->
        stop(ctx, "Reviewer failure: #{reason}", %{"invalid_verdict" => verdict.response})
    end
  end

  defp receive_review(
         ctx,
         _candidate_id,
         _session_id,
         _number,
         {:error, {:malformed_verdict, _code, details}} = error
       )
       when is_map(details) do
    stop(ctx, "Reviewer failure: #{inspect(error)}", %{"invalid_verdict" => details})
  end

  defp receive_review(ctx, _candidate_id, _session_id, _number, {:error, reason}),
    do: stop(ctx, "Reviewer failure: #{inspect(reason)}")

  defp fresh_reviewer(ctx, reviewer, developer) do
    if reviewer == developer or reviewer in ctx.reviewers,
      do:
        {:error,
         "Reviewer session must differ from the Developer session and all prior Reviewers"},
      else: :ok
  end

  defp rework(ctx, session_id, number, reason) do
    with :ok <- inputs_unchanged(ctx),
         {:ok, ctx} <- record_attempt(ctx, %{"status" => "failed", "failure" => reason}) do
      if number >= ctx.config.outer_resumptions do
        stop(
          ctx,
          "stopped after #{ctx.config.outer_resumptions} outer resumptions without an accepting Review: #{reason}"
        )
      else
        begin_attempt(ctx, session_id, number + 1, reason)
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp publish(ctx, candidate_id, session_id, verdict, number) do
    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <- record_attempt(ctx, %{"reference_snapshots" => ctx.references}) do
      attempt = current_attempt(ctx)
      targets = Enum.map(Map.get(attempt, "targets", []), &{&1["target"], &1["output"]})

      case accept(ctx, candidate_id, session_id, verdict, number, attempt["check"], targets, nil) do
        :ok -> :ok
        {:error, reason} -> stop(ctx, reason)
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp inputs_unchanged(ctx) do
    with :ok <- Tracking.verify(ctx.tracking),
         :ok <- approved_unchanged(ctx) do
      references_unchanged(ctx.references, ctx.tracking)
    end
  end

  defp bound_inputs_unchanged(ctx, candidate_id, session_id) do
    with :ok <- inputs_unchanged(ctx),
         {:ok, actual} <- Kogen.Git.candidate_id() do
      cond do
        actual != candidate_id ->
          {:error,
           "Candidate mutated during verification or Review (#{candidate_id} -> #{actual})"}

        not check_unchanged?(ctx) ->
          {:error, "Verification Record mutated after settlement"}

        not Kogen.Check.settled_pass?(candidate_id, session_id) ->
          {:error, "Check no longer settles current Candidate"}

        true ->
          :ok
      end
    end
  end

  defp check_unchanged?(ctx) do
    attempt = current_attempt(ctx)

    read_optional(Kogen.Check.record_path()) == attempt["check_bytes"] and
      read_optional(Kogen.Check.history_path()) == attempt["check_history"]
  end

  defp current_attempt(ctx), do: List.last(ctx.tracking.record["attempts"])

  defp record_attempt(ctx, changes) do
    record = ctx.tracking.record
    attempts = List.update_at(record["attempts"], -1, &Map.merge(&1, changes))

    with {:ok, tracking} <-
           Tracking.update(
             ctx.tracking,
             record |> Map.put("attempts", attempts) |> maybe_failed(changes)
           ) do
      {:ok, %{ctx | tracking: tracking}}
    end
  end

  defp maybe_failed(record, %{"status" => "failed"}), do: Map.put(record, "status", "failed")
  defp maybe_failed(record, _changes), do: record

  defp stop(ctx, reason, details \\ %{}) do
    changes = Map.merge(details, %{"status" => "failed", "failure" => reason})
    result = record_attempt(ctx, changes)

    suffix =
      case result do
        {:ok, _ctx} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    ids = Enum.map_join(ctx.contract.scenarios, ", ", & &1["id"])

    {:error,
     "#{reason}#{suffix}; unresolved scenarios: #{ids}; tracking record: #{ctx.tracking.path}"}
  end

  defp read_check do
    case Kogen.Check.read_record() do
      {:ok, record} -> record
      :error -> nil
    end
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  defp scenario_receipts(ctx) do
    attempt = current_attempt(ctx)
    receipts = [attempt["check"] | Map.get(attempt, "targets", [])]

    Map.new(ctx.contract.scenarios, fn scenario ->
      {scenario["id"], Enum.filter(receipts, &(&1["target"] in scenario["verified_by"]))}
    end)
  end

  defp developer_prompt(ctx, nil) do
    render_developer_prompt(ctx.intent, ctx.contract.text, ctx.targets, ctx.config) <>
      tracking_context(ctx, nil)
  end

  defp developer_prompt(ctx, reason),
    do: resume_feedback(ctx, reason) <> tracking_context(ctx, nil)

  defp tracking_context(ctx, candidate_id) do
    snapshot = %{
      "attempt_token" => ctx.token,
      "candidate_id" => candidate_id,
      "intent_id" => ctx.intent.id,
      "approved_package_digest" => ctx.tracking.record["approved_package_digest"],
      "scenarios" => ctx.contract.scenarios,
      "risks" => ctx.contract.risks,
      "risks_supplied" => ctx.contract.risks_supplied,
      "open_findings" => Tracking.open_findings(ctx.tracking),
      "developer_session_id" => current_attempt(ctx)["developer_session_id"],
      "handoff" => current_attempt(ctx)["handoff"],
      "developer_reference_snapshots" => current_attempt(ctx)["developer_reference_snapshots"],
      "verification_receipts" => current_attempt(ctx)["scenario_receipts"],
      "history" =>
        Enum.map(
          ctx.tracking.record["attempts"],
          &Map.take(
            &1,
            ~w(attempt_token candidate_id developer_session_id number status failure verdict reviewer_session)
          )
        ),
      "findings" => ctx.tracking.record["findings"],
      "retained_finding_evidence" => retained_finding_evidence(ctx)
    }

    "\nRead-only Build-supplied snapshot. Never edit authoritative tracking files.\n" <>
      "KOGEN_TRACKING_CONTEXT\n" <> Jason.encode!(snapshot) <> "\n"
  end

  defp retained_finding_evidence(ctx) do
    paths =
      ctx.tracking.record["findings"]
      |> collect_references()
      |> Enum.map(&Path.relative_to(Path.expand(&1), File.cwd!()))

    Enum.map(ctx.tracking.record["attempts"], fn attempt ->
      %{
        "attempt_token" => attempt["attempt_token"],
        "candidate_id" => attempt["candidate_id"],
        "references" => Map.take(Map.get(attempt, "reference_snapshots", %{}), paths),
        "developer_references" =>
          Map.take(Map.get(attempt, "developer_reference_snapshots", %{}), paths),
        "reviewer_references" =>
          Map.take(Map.get(attempt, "reviewer_reference_snapshots", %{}), paths)
      }
    end)
  end

  defp snapshot_references(value, tracking) do
    value
    |> collect_references()
    |> Enum.map(&Path.relative_to(Path.expand(&1), File.cwd!()))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case cited_bytes(path, tracking) do
        {:ok, bytes} ->
          snapshot = %{
            "sha256" => Base.encode16(:crypto.hash(:sha256, bytes)),
            "content_base64" => Base.encode64(bytes),
            "binding" => reference_binding(path, tracking.path)
          }

          {:cont, {:ok, Map.put(acc, path, snapshot)}}

        {:error, reason} ->
          {:halt, {:error, "could not retain reference #{path}: #{inspect(reason)}"}}
      end
    end)
  end

  defp cited_bytes(path, tracking) do
    if Path.expand(path) == Path.expand(tracking.path),
      do: {:ok, tracking.bytes},
      else: File.read(path)
  end

  defp reference_binding(path, tracking_path) do
    if Path.expand(path) == Path.expand(tracking_path),
      do: "controller_record_version",
      else: "fixed_file"
  end

  defp collect_references(%{"path" => path, "locator" => _locator}), do: [path]

  defp collect_references(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&collect_references/1)

  defp collect_references(list) when is_list(list), do: Enum.flat_map(list, &collect_references/1)
  defp collect_references(_value), do: []

  defp references_unchanged(references, tracking) do
    Enum.reduce_while(references, :ok, fn {path, snapshot}, :ok ->
      case Tracking.verify_reference(tracking, path, snapshot) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Publication copies frozen inputs and adds noncolliding generated evidence.
  # A failed stage/commit restores Approved bytes from controller memory, never
  # from a Complete copy that an external Git hook might have changed.
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
  rescue
    error in File.Error ->
      restore_approved_after_failed_commit(ctx, Path.join(@complete_base, ctx.slug))
      {:error, "publication failed, Approved Intent restored: #{Exception.message(error)}"}
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
    tracking_name = available_tracking_name(complete_dir)
    File.write!(Path.join(complete_dir, tracking_name), ctx.tracking.bytes)

    File.write!(
      Path.join(complete_dir, evidence_name),
      evidence <>
        "\n## Scenario closure\n\n[Self-contained scenario tracking](#{tracking_name}) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.\n"
    )

    File.rm_rf!(approved_dir)

    trailers = [{"Kogen-Intent-ID", intent.id}, {"Kogen-Intent", slug}]

    allowed_paths = [complete_dir <> "/", approved_dir <> "/"]

    expected_entries = package_entries(complete_dir, "")

    publication = %{
      complete_dir: complete_dir,
      approved_dir: approved_dir,
      entries: expected_entries,
      allowed_paths: allowed_paths
    }

    result = finish_publication(ctx, candidate_id, trailers, publication)

    case result do
      :ok ->
        :ok

      {:error, {:before_commit, reason}} ->
        restore_approved_after_failed_commit(ctx, complete_dir)

        {:error,
         "commit failed or final staged tree did not match Candidate, Approved Intent restored, no Commit made: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_publication(ctx, candidate_id, trailers, publication) do
    with :ok <- publication_unchanged(ctx, publication),
         {:ok, publication_id} <- Kogen.Git.candidate_id(),
         :ok <- Kogen.Git.stage_and_verify_candidate(candidate_id, publication.allowed_paths),
         :ok <- Kogen.Git.assert_staged_tree(publication_id),
         :ok <- publication_unchanged(ctx, publication),
         {:ok, _head} <- Kogen.Git.commit_staged(ctx.intent.title, trailers) do
      with :ok <- Kogen.Git.assert_head_tree(publication_id),
           :ok <- publication_unchanged(ctx, publication) do
        :ok
      else
        {:error, reason} ->
          {:error, "post-commit publication integrity assertion failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, {:before_commit, reason}}
    end
  end

  defp publication_unchanged(ctx, publication) do
    references =
      Map.new(ctx.references, fn {path, snapshot} ->
        prefix = publication.approved_dir <> "/"

        published_path =
          if String.starts_with?(path, prefix),
            do: publication.complete_dir <> "/" <> String.replace_prefix(path, prefix, ""),
            else: path

        {published_path, snapshot}
      end)

    with :ok <- Tracking.verify(ctx.tracking),
         :ok <- references_unchanged(references, ctx.tracking) do
      cond do
        File.exists?(publication.approved_dir) ->
          {:error, "Approved package reappeared during publication"}

        not check_unchanged?(ctx) ->
          {:error, "Verification Record mutated during publication"}

        package_entries(publication.complete_dir, "") != publication.entries ->
          {:error, "Complete evidence or copied Approved package mutated during publication"}

        true ->
          :ok
      end
    end
  rescue
    error in File.Error ->
      {:error, "publication integrity check failed: #{Exception.message(error)}"}
  end

  defp restore_approved_after_failed_commit(ctx, complete_dir) do
    approved_dir = Path.join(@approved_base, ctx.slug)
    File.rm_rf!(approved_dir)

    Enum.each(ctx.approved_entries, fn
      {relative, :directory, _mode} ->
        File.mkdir_p!(Path.join(approved_dir, relative))

      {relative, :regular, mode, bytes} ->
        path = Path.join(approved_dir, relative)
        File.write!(path, bytes)
        File.chmod!(path, Bitwise.band(mode, 0o7777))
    end)

    ctx.approved_entries
    |> Enum.reverse()
    |> Enum.each(fn
      {relative, :directory, mode} ->
        File.chmod!(Path.join(approved_dir, relative), Bitwise.band(mode, 0o7777))

      _entry ->
        :ok
    end)

    File.rm_rf!(complete_dir)

    case Kogen.Git.reject_candidate_blinding_index_flags() do
      :ok -> Kogen.Git.unstage_all()
      {:error, _reason} -> :ok
    end
  end

  defp available_tracking_name(dir) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = if index == 0, do: "scenario-tracking.json", else: "scenario-tracking-#{index}.json"

      case File.lstat(Path.join(dir, name)) do
        {:error, :enoent} -> name
        _ -> nil
      end
    end)
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
        findings -> Jason.encode!(findings)
      end

    verdict_json = Jason.encode!(verdict.response)

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
    |> String.replace("{{execution_policy}}", Kogen.ExecutionPolicy.render(config, "developer"))
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
    |> String.replace("{{execution_policy}}", Kogen.ExecutionPolicy.render(config, "reviewer"))
  end

  defp tail_of(str, n) do
    String.slice(str, -n, n)
  end
end
