defmodule Kogen.Build do
  @moduledoc """
  The synchronous Build loop: preconditions, one Developer launch, Stop-hook
  Check settlement, declared-target verification, a fresh Review, bounded
  Rework (at most `outer_resumptions` resumes of the exact Developer
  thread), and one ordinary Git Commit carrying the Intent identity.

  After Stop verification settles, controller code builds the handoff report
  (`Kogen.Build.Report`). The Developer's final message is free prose that no
  Kogen code parses: Build records it as unverified notes and asks TypeSafe Jev
  (`Kogen.Jev`) once what the Developer says about each item. Only a confident
  contract objection stops the Build, unless an earlier Stop cycle of the same
  attempt failed and its final cycle passed on the settled Candidate: that
  objection is superseded and reaches the Reviewer as an advisory item. Every
  other reading, and any Jev failure, reaches the fresh Reviewer as advisory
  notes. Each Reviewer starts from one bounded review packet per attempt
  (`Kogen.Build.ReviewPacket`).
  """
  use Boundary,
    deps: [
      Kogen.Intent,
      Kogen.Harness,
      Kogen.Check,
      Kogen.Git,
      Kogen.VerificationPolicy,
      Kogen.ExecutionPolicy,
      Kogen.Jev
    ]

  alias Kogen.Build.{
    Contract,
    FailureSignature,
    GuardedPaths,
    Report,
    ReviewPacket,
    TargetEvidence,
    Tracking,
    Verification,
    VerificationPlan
  }

  @lock_path ".kogen/build.lock"
  @approved_base ".kogen/intents/approved"
  @complete_base ".kogen/intents/complete"
  @publication_file_limit 5_242_880
  @publication_total_limit 10_485_760

  @doc """
  Runs one Build of the Approved Intent `slug` on the named `route`, or on the
  configured `default_route` when `route` is `nil`. Configuration is resolved
  exactly once, before any harness readiness or launch; every later launch,
  resumption, Stop verification context and Review uses that frozen route.
  """
  @spec run(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def run(slug, route \\ nil) do
    with {:ok, config} <- Kogen.Intent.read_config(".kogen/config.yaml", route),
         {:ok, intent} <- Kogen.Intent.read(slug, @approved_base),
         {:ok, approved_entries} <- read_approved_entries(slug),
         :ok <- preflight_approved_budget(approved_entries),
         :ok <- Kogen.Git.reject_candidate_blinding_index_flags(),
         :ok <- check_clean_worktree(),
         :ok <- check_branch_attached(),
         :ok <- check_complete_absent(slug),
         :ok <- Kogen.Jev.key_present() do
      case acquire_lock() do
        :ok ->
          try do
            with :ok <- check_make_check_target() do
              do_build(slug, intent, config, approved_entries)
            end
          after
            release_lock()
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp preflight_approved_budget(entries) do
    files = for {path, :regular, _mode, bytes} <- entries, do: {path, byte_size(bytes)}
    oversized = Enum.filter(files, fn {_path, size} -> size > @publication_file_limit end)
    total = Enum.reduce(files, 0, fn {_path, size}, sum -> sum + size end)

    if oversized == [] and total <= @publication_total_limit do
      :ok
    else
      offenders =
        Enum.map_join(oversized, ", ", fn {path, size} -> "#{inspect(path)}=#{size}" end)

      largest =
        files
        |> Enum.sort_by(fn {_path, size} -> -size end)
        |> Enum.take(8)
        |> Enum.map_join(", ", fn {path, size} -> "#{inspect(path)}=#{size}" end)

      {:error,
       "Approved Intent cannot fit publication budget before provider launch: files over #{@publication_file_limit} bytes: #{offenders}; package total #{total}/#{@publication_total_limit}; largest contributors: #{largest}. Return to Shaping to change the Approved package."}
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
  defp do_build(slug, intent, config, approved_entries) do
    with {:ok, contract} <- Contract.load(Path.join(@approved_base, slug)),
         {:ok, catalog} <- VerificationPlan.load(),
         {:ok, plan} <-
           VerificationPlan.build(contract.scenarios, intent.may_change_guarded_paths, catalog),
         :ok <- Kogen.VerificationPolicy.preflight(catalog.ordered_targets),
         {:ok, guarded_snapshot} <- GuardedPaths.capture(),
         {:ok, runtime} <- Kogen.Harness.open(config),
         {:ok, tracking} <- Tracking.new(intent, contract, approved_entries, config) do
      ctx = %{
        slug: slug,
        intent: intent,
        config: config,
        contract: contract,
        targets: plan.targets,
        plan: plan,
        catalog: catalog,
        guarded_snapshot: guarded_snapshot,
        policy_environment: Kogen.VerificationPolicy.environment(catalog.ordered_targets),
        approved_entries: approved_entries,
        tracking: tracking,
        token: nil,
        reviewers: [],
        references: %{},
        review_packet: nil,
        runtime: runtime
      }

      try do
        begin_attempt(ctx, nil, 0, nil)
      after
        Kogen.Harness.close(runtime)
      end
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
        # The explicit error branch preserves the updated tracking owner.
        # credo:disable-for-next-line Credo.Check.Readability.WithSingleClause
        with {:ok, execution} <-
               Verification.initialize(
                 tracking.path,
                 token,
                 number,
                 ctx.targets,
                 ctx.config.verification_retries,
                 ctx.plan
               ) do
          ctx =
            Map.merge(ctx, %{
              tracking: tracking,
              token: token,
              references: %{},
              review_packet: nil,
              execution: execution
            })

          # Keeping context retention adjacent to initialization makes the
          # ownership transition auditable despite the deliberate nesting.
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case record_attempt(ctx, %{
                 "verification_context" => %{
                   "path" => Path.relative_to(execution.context_path, File.cwd!()),
                   "sha256" => execution.context_sha256,
                   "content_base64" => Base.encode64(execution.context_bytes)
                 }
               }) do
            {:ok, ctx} -> launch_attempt(ctx, session_id, number, reason)
            {:error, error} -> stop(ctx, error)
          end
        else
          {:error, error} -> stop(%{ctx | tracking: tracking}, error)
        end

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  defp launch_attempt(ctx, session_id, number, reason) do
    with :ok <- inputs_unchanged(ctx),
         true <- VerificationPlan.unchanged?(ctx.catalog),
         :ok <- Kogen.VerificationPolicy.preflight(ctx.catalog.ordered_targets),
         :ok <- Kogen.Check.invalidate!() do
      prompt = developer_prompt(ctx, reason)

      result =
        if session_id do
          Kogen.Harness.resume_build_developer(
            session_id,
            prompt,
            ctx.config.developer.model,
            ctx.config.developer.effort,
            ctx.policy_environment ++ Verification.environment(ctx.execution),
            Kogen.Harness.launch_context(ctx.runtime)
          )
        else
          Kogen.Harness.launch_build_developer(
            prompt,
            ctx.config.developer.model,
            ctx.config.developer.effort,
            ctx.policy_environment ++ Verification.environment(ctx.execution),
            Kogen.Harness.launch_context(ctx.runtime)
          )
        end

      receive_developer(ctx, session_id, number, result)
    else
      false -> stop(ctx, "verification target catalog changed after admission")
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp receive_developer(ctx, expected, number, {:ok, turn}) do
    if expected && turn.session_id != expected do
      stop(
        ctx,
        "resume created a new session (expected #{expected}, got #{turn.session_id})",
        %{
          "developer_session_id" => turn.session_id,
          "developer_notes" => notes_record(turn.message),
          "developer_invocation" => invocation_evidence(turn.invocation_evidence)
        }
      )
    else
      settle(
        ctx,
        turn.session_id,
        number,
        Map.fetch!(turn, :message),
        invocation_evidence(turn.invocation_evidence)
      )
    end
  end

  defp receive_developer(
         ctx,
         expected,
         number,
         {:error, {:developer_transport_failure, reason, evidence}}
       ) do
    session_id = evidence[:session_id]

    if expected && session_id != expected do
      stop(ctx, "resume created a new session (expected #{expected}, got #{session_id})", %{
        "developer_session_id" => session_id,
        "developer_invocation" => invocation_evidence(evidence)
      })
    else
      settle_transport_failure(ctx, number, reason, evidence)
    end
  end

  defp receive_developer(ctx, _expected, _number, {:error, reason}) do
    case post_developer_inputs_unchanged(ctx) do
      :ok -> stop(ctx, "harness failure during Developer turn: #{inspect(reason)}")
      {:error, guard_reason} -> stop(ctx, guard_reason)
    end
  end

  # No Kogen code parses `notes`: they are recorded verbatim as unverified
  # claims and only Jev reads them. Every outcome below is decided by
  # controller code from settled verification, the Candidate and Jev's
  # validated answers, so no handoff-format failure exists.
  defp settle(ctx, session_id, number, notes, invocation) do
    with :ok <- post_developer_inputs_unchanged(ctx),
         {:ok, candidate_id} <- Kogen.Git.candidate_id(),
         {:ok, ctx, verification} <- settle_verification(ctx, session_id, candidate_id),
         receipts = normalized_final_receipts(verification),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "candidate_id" => candidate_id,
             "developer_session_id" => session_id,
             "developer_notes" => notes_record(notes),
             "developer_invocation" => invocation,
             "check" => List.first(receipts),
             "targets" => Enum.drop(receipts, 1)
           }),
         {:ok, ctx, jev} <- read_notes(ctx, candidate_id, notes) do
      settle_outcome(ctx, candidate_id, session_id, number, notes, verification, jev)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp settle_outcome(ctx, candidate_id, session_id, number, notes, verification, jev) do
    objections = Kogen.Jev.objections(jev)
    exhausted? = verification["terminal_state"] != "passed"

    superseded =
      ReviewPacket.superseded_objection(
        verification,
        %{attempt_token: ctx.token, developer_session_id: session_id, candidate_id: candidate_id},
        objections,
        Kogen.Jev.objection_threshold()
      )

    cond do
      objections == [] ->
        settle_passing(ctx, candidate_id, session_id, number, verification, jev)

      superseded ->
        case record_attempt(ctx, %{"superseded_objection" => superseded}) do
          {:ok, ctx} -> settle_passing(ctx, candidate_id, session_id, number, verification, jev)
          {:error, error} -> stop(ctx, error)
        end

      true ->
        cannot_comply(ctx, number, notes, objections, exhausted?, verification)
    end
  end

  defp settle_passing(ctx, candidate_id, session_id, number, verification, jev) do
    exhausted? = verification["terminal_state"] != "passed"
    missing = VerificationPlan.missing_selectors(ctx.plan, ctx.catalog)

    cond do
      exhausted? ->
        stop(ctx, terminal_exhaustion_reason(ctx, verification))

      missing != [] ->
        unfinished_work(ctx, session_id, number, missing)

      true ->
        report_and_review(ctx, candidate_id, session_id, number, jev)
    end
  end

  defp notes_record(notes) when is_binary(notes) do
    %{
      "label" => "unverified Developer notes; recorded verbatim and never parsed by Kogen code",
      "sha256" => Base.encode16(:crypto.hash(:sha256, notes), case: :lower),
      "byte_count" => byte_size(notes),
      "content_base64" => Base.encode64(notes),
      "text" => if(String.valid?(notes), do: notes)
    }
  end

  defp notes_record(_notes), do: notes_record("")

  defp read_notes(ctx, candidate_id, notes) do
    jev =
      notes
      |> Kogen.Jev.read_notes(jev_items(ctx))
      |> Map.merge(%{"attempt_token" => ctx.token, "candidate_id" => candidate_id})

    with {:ok, ctx} <- record_attempt(ctx, %{"jev" => jev}), do: {:ok, ctx, jev}
  end

  defp jev_items(ctx) do
    Enum.map(ctx.contract.scenarios, &%{"kind" => "scenario", "id" => &1["id"]}) ++
      Enum.map(ctx.contract.risks, &%{"kind" => "risk", "id" => &1["id"]}) ++
      Enum.map(Tracking.open_findings(ctx.tracking), &%{"kind" => "finding", "id" => &1["id"]})
  end

  @cannot_comply_prefix "Developer cannot comply as approved; return to Shaping:"
  @quote_limit 2_000

  defp cannot_comply(ctx, number, notes, objections, exhausted?, verification) do
    {quote, truncated?} = quote_notes(notes)

    items =
      Enum.map_join(objections, ", ", fn item ->
        "#{item["kind"]} `#{item["id"]}` (Jev confidence #{Kogen.Jev.format(item["confidence"])})"
      end)

    location =
      "#{ctx.tracking.path} attempt #{number} developer_notes"

    quoted =
      if truncated?,
        do:
          "\"#{quote}\" [notes truncated at #{@quote_limit} of #{String.length(notes)} characters; full notes in #{location}]",
        else: "\"#{quote}\""

    reason =
      "#{@cannot_comply_prefix} Jev (#{Kogen.Jev.model()}) read a contract objection at or above #{Kogen.Jev.objection_threshold()} for #{items}. Developer's notes: #{quoted}"

    reason =
      if exhausted?,
        do: reason <> "; " <> terminal_exhaustion_reason(ctx, verification),
        else: reason

    case record_attempt(ctx, %{
           "outcome" => "cannot_comply",
           "cannot_comply" => %{
             "items" => objections,
             "threshold" => Kogen.Jev.objection_threshold(),
             "notes_quote" => quote,
             "notes_truncated" => truncated?
           }
         }) do
      {:ok, ctx} -> stop(ctx, reason)
      {:error, error} -> stop(ctx, error)
    end
  end

  defp quote_notes(notes) do
    if String.length(notes) > @quote_limit,
      do: {String.slice(notes, 0, @quote_limit), true},
      else: {notes, false}
  end

  defp unfinished_work(ctx, session_id, number, missing) do
    reason =
      Enum.map_join(missing, "; ", &"Unfinished work: missing declared proof selector #{&1}")

    case record_attempt(ctx, %{
           "outcome" => "unfinished_work",
           "unfinished_work" => %{"missing_selectors" => missing}
         }) do
      {:ok, ctx} -> rework(ctx, session_id, number, reason)
      {:error, error} -> stop(ctx, error)
    end
  end

  defp report_and_review(ctx, candidate_id, session_id, number, jev) do
    attempt = current_attempt(ctx)

    with {:ok, changes} <- candidate_changes(candidate_id),
         report =
           Report.build(%{
             contract: ctx.contract,
             attempt_token: ctx.token,
             candidate_id: candidate_id,
             open_findings: Tracking.open_findings(ctx.tracking),
             changes: changes,
             check: attempt["check"],
             targets: Map.get(attempt, "targets", []),
             jev: jev
           }),
         {:ok, references} <- snapshot_references(report, ctx.tracking),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "outcome" => "settled",
             "handoff" => report,
             "developer_reference_snapshots" => references
           }) do
      review(%{ctx | references: references}, candidate_id, session_id, number)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  # Paths that differ between the settled Candidate tree and HEAD.
  defp candidate_changes(candidate_id) do
    case System.cmd(
           "git",
           [
             "-c",
             "core.filemode=true",
             "diff",
             "--name-status",
             "--no-renames",
             "-z",
             "HEAD",
             candidate_id,
             "--"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok,
         output
         |> String.split(<<0>>, trim: true)
         |> Enum.chunk_every(2)
         |> Enum.map(fn [status, path] -> {path, change_kind(status)} end)}

      {output, _status} ->
        {:error, "could not derive Candidate changes: #{String.trim(output)}"}
    end
  end

  defp change_kind("A"), do: "added"
  defp change_kind("D"), do: "deleted"
  defp change_kind(_status), do: "modified"

  defp settle_transport_failure(ctx, number, reason, evidence) do
    session_id = evidence[:session_id]

    candidate =
      case post_developer_inputs_unchanged(ctx) do
        :ok -> Kogen.Git.candidate_id()
        {:error, _reason} = error -> error
      end

    case candidate do
      {:ok, candidate_id} ->
        case settle_verification(ctx, session_id, candidate_id) do
          {:ok, ctx, %{"terminal_state" => "exhausted"} = verification} ->
            stop(ctx, terminal_exhaustion_reason(ctx, verification), %{
              "developer_session_id" => session_id,
              "developer_invocation" => invocation_evidence(evidence)
            })

          {:ok, ctx, _passed} ->
            stop(ctx, "harness failure during Developer turn: #{inspect(reason)}", %{
              "developer_session_id" => session_id,
              "developer_invocation" => invocation_evidence(evidence),
              "outer_attempt" => number
            })

          {:error, _settlement_reason} ->
            stop(ctx, "harness failure during Developer turn: #{inspect(reason)}", %{
              "developer_invocation" => invocation_evidence(evidence)
            })
        end

      {:error, _} ->
        stop(ctx, "harness failure during Developer turn: #{inspect(reason)}", %{
          "developer_invocation" => invocation_evidence(evidence)
        })
    end
  end

  defp post_developer_inputs_unchanged(ctx) do
    with :ok <- inputs_unchanged(ctx),
         true <- VerificationPlan.unchanged?(ctx.catalog),
         :ok <- GuardedPaths.check(ctx.guarded_snapshot, ctx.intent.may_change_guarded_paths) do
      :ok
    else
      false -> {:error, "verification target catalog changed after admission"}
      {:error, _} = error -> error
    end
  end

  defp settle_verification(ctx, session_id, candidate_id) do
    case Verification.settle(ctx.execution, session_id, candidate_id) do
      {:ok, execution, verification} ->
        ctx = %{ctx | execution: execution}

        previous =
          ctx.tracking.record["attempts"]
          |> Enum.flat_map(&Map.get(&1, "failure_signatures", []))

        signatures =
          verification["cycles"]
          |> Enum.map_reduce(previous, fn cycle, seen ->
            signature = FailureSignature.derive(cycle, execution.context, ctx.catalog, seen)
            {signature, seen ++ [signature]}
          end)
          |> elem(0)

        case record_attempt(ctx, %{
               "verification" => verification,
               "failure_signatures" => signatures,
               "verification_state" => %{
                 "path" => Path.relative_to(execution.state_path, File.cwd!()),
                 "sha256" => Base.encode16(:crypto.hash(:sha256, execution.state_bytes)),
                 "content_base64" => Base.encode64(execution.state_bytes)
               }
             }) do
          {:ok, ctx} -> {:ok, ctx, verification}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, "verification settlement integrity failure: #{reason}"}
    end
  end

  defp terminal_exhaustion_reason(ctx, verification) do
    cycle = List.last(verification["cycles"])
    target = cycle["failed_target"] || List.last(cycle["receipts"])["target"]

    signature =
      ctx.tracking.record["attempts"]
      |> List.last()
      |> Map.get("failure_signatures", [])
      |> List.last()

    "verification retries exhausted after cycle #{cycle["sequence"]} failed at make #{target}; signature: #{Jason.encode!(signature)}"
  end

  defp normalized_final_receipts(verification) do
    cycle = List.last(verification["cycles"])

    Enum.map(Verification.final_receipts(verification), fn receipt ->
      receipt
      |> Map.put_new("session_id", receipt["developer_session_id"])
      |> Map.put_new("candidate", receipt["candidate_id"])
      |> Map.put_new("reason", receipt["output"])
      |> Map.put_new("finished_at", cycle["finished_at"] || verification["finished_at"])
    end)
  end

  defp review(ctx, candidate_id, session_id, number) do
    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "scenario_receipts" => scenario_receipts(ctx),
             "reference_snapshots" => ctx.references
           }),
         {:ok, ctx} <- write_review_packet(ctx, candidate_id, number),
         :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id) do
      prompt =
        render_reviewer_prompt(ctx.intent, candidate_id, ctx.config) <>
          reviewer_notes_section(ctx) <> task_context(ctx, candidate_id, "reviewer")

      result =
        Kogen.Harness.launch_reviewer(
          prompt,
          ctx.config.reviewer.model,
          ctx.config.reviewer.effort,
          Kogen.Harness.launch_context(ctx.runtime)
        )

      receive_review(ctx, candidate_id, session_id, number, result)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  # One immutable packet per attempt, written before launch. Its binding lives
  # in controller state and in the attempt, and every later input check
  # verifies it, so a rebuilt or edited packet stops the Build.
  defp write_review_packet(ctx, candidate_id, number) do
    input = %{
      record: ctx.tracking.record,
      record_path: ctx.tracking.path,
      record_bytes: ctx.tracking.bytes,
      candidate_id: candidate_id,
      open_findings: Enum.map(Tracking.open_findings(ctx.tracking), & &1["id"])
    }

    with {:ok, bytes} <- ReviewPacket.build(input),
         {:ok, binding} <-
           ReviewPacket.write(ctx.tracking.path, number, bytes, ctx.token, candidate_id),
         {:ok, ctx} <- record_attempt(ctx, %{"review_packet" => binding}) do
      {:ok, %{ctx | review_packet: binding}}
    end
  end

  defp review_packets_unchanged(ctx) do
    attempts = ctx.tracking.record["attempts"]
    current = List.last(attempts)["review_packet"]

    if ctx.review_packet != nil and ctx.review_packet != current do
      {:error, "review packet binding changed after it was written"}
    else
      Enum.reduce_while(attempts, :ok, &review_packet_unchanged/2)
    end
  end

  defp review_packet_unchanged(attempt, :ok) do
    case review_packet_unchanged(attempt) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp review_packet_unchanged(%{"review_packet" => binding} = attempt) do
    if binding["attempt_token"] == attempt["attempt_token"] and
         binding["candidate_id"] == attempt["candidate_id"],
       do: ReviewPacket.verify(binding),
       else: {:error, "review packet is not bound to its attempt and Candidate"}
  end

  defp review_packet_unchanged(_attempt), do: :ok

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
         :ok <- approved_unchanged(ctx),
         :ok <- references_unchanged(ctx.references, ctx.tracking),
         :ok <- Tracking.verify_record_versions(ctx.tracking),
         :ok <- review_packets_unchanged(ctx) do
      target_evidence_unchanged(ctx.tracking)
    end
  end

  defp bound_inputs_unchanged(ctx, candidate_id, _session_id) do
    with :ok <- inputs_unchanged(ctx),
         {:ok, actual} <- Kogen.Git.candidate_id() do
      cond do
        actual != candidate_id ->
          {:error,
           "Candidate mutated during verification or Review (#{candidate_id} -> #{actual})"}

        not Verification.unchanged?(ctx.execution) ->
          {:error, "unified Verification Record mutated after settlement"}

        true ->
          :ok
      end
    end
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

  defp scenario_receipts(ctx) do
    attempt = current_attempt(ctx)
    receipts = [attempt["check"] | Map.get(attempt, "targets", [])]

    Map.new(ctx.contract.scenarios, fn scenario ->
      {scenario["id"], Enum.filter(receipts, &(&1["target"] in scenario["verified_by"]))}
    end)
  end

  defp developer_prompt(ctx, nil) do
    render_developer_prompt(ctx.intent, ctx.contract.text, ctx.targets, ctx.config) <>
      task_context(ctx, nil, "developer")
  end

  defp developer_prompt(ctx, reason) do
    render_developer_prompt(ctx.intent, ctx.contract.text, ctx.targets, ctx.config) <>
      "\n\n" <> resume_feedback(ctx, reason) <> task_context(ctx, nil, "developer")
  end

  defp task_context(ctx, candidate_id, role) do
    context = %{
      "version" => 1,
      "role" => role,
      "working_directory" => File.cwd!(),
      "approved_path" => Path.join(@approved_base, ctx.slug),
      "tracking_path" => ctx.tracking.path,
      "tracking_sections" => ["attempts", "findings", "scenarios", "risks"],
      "attempt_token" => ctx.token,
      "candidate_id" => candidate_id,
      "intent_id" => ctx.intent.id,
      "developer_session_id" => current_attempt(ctx)["developer_session_id"]
    }

    context = if role == "reviewer", do: Map.merge(context, reviewer_context(ctx)), else: context

    "\nRead-only locator packet. Never edit authoritative tracking files.\n" <>
      "KOGEN_TASK_CONTEXT\n" <> Jason.encode!(context) <> "\n"
  end

  @report_statement "The handoff report (review packet `handoff`) is controller-built and contains no Developer self-assessment; you are responsible for finding unfinished or plausible-looking-only scenarios."
  @notes_statement "The Developer's notes (review packet `developer_notes`), including prose responses to open findings, are unverified claims."
  @packet_statement "Start from the review packet: it is your evidence source, bound to this attempt and Candidate. A cut or left-out item carries its digest and a record locator. The full tracking record is an audit locator only; never dump it whole. The packet never replaces inspecting the Candidate: read any Candidate file and run read-only commands."
  @jev_statement "Jev only read the Developer's words and never judged the code. Its readings are advisory, never findings or verification; a confident \"unfinished\" reading never routes rework by itself, only your verdict does."
  @changes_statement "`changed_affected_paths` lists files that changed relative to HEAD, not where each behaviour lives."

  defp reviewer_context(ctx) do
    jev = current_attempt(ctx)["jev"] || %{}

    %{
      "evidence_source" => "review_packet",
      "review_packet" => Map.take(ctx.review_packet, ["path", "sha256", "byte_count"]),
      "review_packet_use" => @packet_statement,
      "tracking_record" => %{
        "path" => ctx.tracking.path,
        "byte_count" => byte_size(ctx.tracking.bytes),
        "use" => "audit locator only; never dump the whole record"
      },
      "handoff_report" => @report_statement,
      "developer_notes" => @notes_statement,
      "changed_affected_paths" => @changes_statement,
      "jev_reading" => %{
        "model" => jev["model"],
        "outcome" => jev["outcome"],
        "advisory" => @jev_statement,
        "items" => Kogen.Jev.advisory(jev)
      }
    }
  end

  defp reviewer_notes_section(ctx) do
    jev = current_attempt(ctx)["jev"] || %{}

    lines =
      Enum.map_join(Kogen.Jev.advisory(jev), "\n", fn item ->
        "- #{item["kind"]} `#{item["id"]}`: " <> Enum.join(item["notes"], "; ")
      end)

    "\n\n## Controller report, Developer notes and advisory Jev reading\n\n" <>
      Enum.join(
        [
          "Review packet: `#{ctx.review_packet["path"]}` (#{ctx.review_packet["byte_count"]} bytes, sha256 #{ctx.review_packet["sha256"]}). " <>
            @packet_statement,
          @report_statement,
          @notes_statement,
          @changes_statement
        ],
        "\n"
      ) <>
      "\n\nAdvisory Jev (#{Kogen.Jev.model()}) reading of the Developer's notes. " <>
      @jev_statement <> "\n\n" <> lines <> "\n"
  end

  defp snapshot_references(value, tracking) do
    value
    |> collect_references()
    |> Enum.map(&Path.relative_to(Path.expand(&1), File.cwd!()))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case snapshot_reference(path, tracking) do
        {:ok, snapshot} ->
          {:cont, {:ok, Map.put(acc, path, snapshot)}}

        {:error, reason} when is_binary(reason) ->
          {:halt, {:error, "could not retain reference #{path}: #{reason}"}}

        {:error, reason} ->
          {:halt, {:error, "could not retain reference #{path}: #{inspect(reason)}"}}
      end
    end)
  end

  # A citation of this Build's own record keeps metadata and an immutable
  # sidecar of the exact cited version, never an inline copy of the record.
  defp snapshot_reference(path, tracking) do
    if Path.expand(path) == Path.expand(tracking.path) do
      Tracking.retain_record_version(tracking, tracking.bytes)
    else
      with {:ok, bytes} <- File.read(path) do
        {:ok,
         %{
           "sha256" => Base.encode16(:crypto.hash(:sha256, bytes)),
           "content_base64" => Base.encode64(bytes),
           "binding" => "fixed_file"
         }}
      end
    end
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

  defp target_evidence_unchanged(tracking) do
    tracking.record["attempts"]
    |> Enum.flat_map(fn attempt ->
      direct = Map.get(attempt, "targets", [])

      cycles =
        attempt
        |> Map.get("verification", %{})
        |> Map.get("cycles", [])
        |> Enum.flat_map(&Map.get(&1, "receipts", []))

      direct ++ cycles
    end)
    |> Enum.flat_map(fn receipt ->
      case Map.fetch(receipt, "target_evidence") do
        {:ok, snapshot} -> [snapshot]
        :error -> []
      end
    end)
    |> Enum.reduce_while(:ok, fn snapshot, :ok ->
      case TargetEvidence.verify(snapshot) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "bound target evidence changed: #{reason}"}}
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
         _dev_result
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
        ctx.config
      )

    evidence_name = available_evidence_name(complete_dir)
    summary_name = available_summary_name(complete_dir)
    summary = build_summary(ctx, candidate_id, session_id, verdict)

    File.write!(
      Path.join(complete_dir, summary_name),
      Jason.encode_to_iodata!(summary, pretty: true)
    )

    File.write!(
      Path.join(complete_dir, evidence_name),
      evidence <>
        "\n## Exact evidence\n\n[Compact Build summary](#{summary_name}) contains concise results. The full controller record remains local at `#{ctx.tracking.path}` and is not committed. From the checkout root, verify it with `shasum -a 256 #{ctx.tracking.path}` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.\n"
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
         :ok <- Kogen.Git.validate_staged_publication(),
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
         :ok <- references_unchanged(references, ctx.tracking),
         :ok <- Tracking.verify_record_versions(ctx.tracking),
         :ok <- review_packets_unchanged(ctx),
         :ok <- target_evidence_unchanged(ctx.tracking) do
      cond do
        File.exists?(publication.approved_dir) ->
          {:error, "Approved package reappeared during publication"}

        not Verification.unchanged?(ctx.execution) ->
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

  defp available_summary_name(dir) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = if index == 0, do: "build-summary.json", else: "build-summary-#{index}.json"

      case File.lstat(Path.join(dir, name)) do
        {:error, :enoent} -> name
        _ -> nil
      end
    end)
  end

  defp build_summary(ctx, candidate_id, developer_session_id, verdict) do
    record = ctx.tracking.record
    attempts = Enum.map(record["attempts"], &summary_attempt/1)
    final_verdict = record["attempts"] |> List.last() |> Map.fetch!("verdict")

    %{
      "format" => "kogen-build-summary",
      "schema_version" => 1,
      "intent" => Map.take(record["intent"], ["id", "slug", "title"]),
      "build_id" => ctx.tracking.path |> Path.dirname() |> Path.basename(),
      "route" => %{"name" => ctx.config.route, "harness" => ctx.config.harness},
      "candidate_id" => candidate_id,
      "developer_session_id" => developer_session_id,
      "attempts" => attempts,
      "scenarios" => Map.get(final_verdict, "scenarios", []),
      "risks" => Enum.map(record["risks"], &Map.take(&1, ["id"])),
      "findings" => Enum.map(record["findings"], &summary_finding/1),
      "review" => %{"outcome" => verdict.verdict, "session_id" => verdict.session_id},
      "full_record" => %{
        "format" => "kogen-scenario-tracking-record",
        "schema_version" => record["schema_version"],
        "path" => ctx.tracking.path,
        "sha256" => Base.encode16(:crypto.hash(:sha256, ctx.tracking.bytes), case: :lower),
        "byte_count" => byte_size(ctx.tracking.bytes)
      }
    }
  end

  defp summary_attempt(attempt) do
    receipts = [attempt["check"] | Map.get(attempt, "targets", [])] |> Enum.reject(&is_nil/1)

    %{
      "number" => attempt["number"],
      "attempt_token" => attempt["attempt_token"],
      "status" => attempt["status"],
      "failure_kind" => attempt["failure"] && failure_category(attempt["failure"]),
      "developer_session_id" => attempt["developer_session_id"],
      "reviewer_session_id" => attempt["reviewer_session"],
      "candidate_id" => attempt["candidate_id"],
      "targets" =>
        Enum.map(
          receipts,
          &Map.take(&1, [
            "target",
            "status",
            "exit_code",
            "started_at",
            "finished_at",
            "candidate_id",
            "attempt_token",
            "session_id"
          ])
        )
    }
  end

  defp summary_finding(finding) do
    disposition = finding |> Map.get("disposition_history", []) |> List.last()

    finding
    |> Map.take(["id", "origin", "status"])
    |> Map.put("current_disposition", disposition)
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
         route
       ) do
    findings_text = Enum.map_join(verdict.findings, ", ", &Map.get(&1, "id", "finding"))
    findings_text = if findings_text == "", do: "(none)", else: findings_text

    check_section = """
    ## Check (Stop hook Verification Record, bound to this Candidate)

    - status: `#{Map.get(check_record, "status")}`
    - exit_code: `#{Map.get(check_record, "exit_code")}`
    - finished_at: `#{Map.get(check_record, "finished_at")}`
    - session_id: `#{Map.get(check_record, "session_id")}`
    """

    targets_section =
      case target_results do
        [] ->
          "## Declared targets\n\n(none beyond `check`)\n"

        results ->
          bodies =
            Enum.map_join(results, "\n", fn {name, _out} ->
              "- `make #{name}`: settled (exact output remains in the full local record)"
            end)

          "## Declared targets (beyond `check`)\n\n" <> bodies
      end

    """
    # Complete evidence: #{intent.title}

    - Route: `#{route.route}` (harness `#{route.harness}`)
    - Candidate id: `#{candidate_id}`
    - Developer session id: `#{developer_session_id}`
    - Reviewer session id: `#{verdict.session_id}`
    - Outer resumptions used: #{resumptions_used}
    #{check_section}
    #{targets_section}
    ## Reviewer Verdict

    - Reviewer verdict: #{verdict.verdict}
    - Reviewer findings: #{findings_text}
    """
  end

  @doc false
  # credo:disable-for-lines:45 Credo.Check.Refactor.Nesting
  def render_developer_prompt(intent, _scenarios_text, targets, config) do
    readiness =
      case VerificationPlan.load() do
        {:ok, catalog} ->
          # Rendering remains fail-closed in the real Build, which already
          # validated the same Approved proof data. This public helper retains
          # its historical arity for prompt fixture consumers.
          case Contract.load(Path.join(@approved_base, intent.slug)) do
            {:ok, contract} ->
              case VerificationPlan.build(
                     contract.scenarios,
                     intent.may_change_guarded_paths,
                     catalog
                   ) do
                {:ok, plan} ->
                  changed =
                    case Kogen.Git.changed_paths() do
                      {:ok, paths} -> paths
                      _ -> []
                    end

                  VerificationPlan.readiness_commands(plan, changed)

                _ ->
                  []
              end

            _ ->
              []
          end

        _ ->
          []
      end

    "priv/kogen/prompts/developer.md"
    |> File.read!()
    |> String.replace("{{intent_title}}", intent.title)
    |> String.replace("{{intent_id}}", intent.id)
    |> String.replace("{{approved_path}}", Path.join(@approved_base, intent.slug))
    |> String.replace(
      "{{may_change_guarded_paths}}",
      Enum.join(intent.may_change_guarded_paths, ", ")
    )
    |> String.replace(
      "{{verification_ownership}}",
      Kogen.VerificationPolicy.developer_instruction(targets)
    )
    |> String.replace("{{readiness_commands}}", Enum.join(readiness, "\n"))
    |> String.replace("{{execution_policy}}", Kogen.ExecutionPolicy.render(config, "developer"))
  end

  defp resume_feedback(ctx, reason) do
    "Rework required (category: #{failure_category(reason)}; record: #{ctx.tracking.path}).\n" <>
      "Read the preceding failed attempt's `failure` field for full details; " <>
      "select the current attempt by its supplied token.\n"
  end

  defp failure_category(reason) do
    cond do
      String.starts_with?(reason, "settled Check failure:") -> "check_settlement"
      String.starts_with?(reason, "declared-target failure:") -> "declared_target"
      String.starts_with?(reason, "Reviewer findings:") -> "review_rework"
      String.starts_with?(reason, "Unfinished work:") -> "unfinished_work"
      String.starts_with?(reason, @cannot_comply_prefix) -> "cannot_comply"
      true -> "rework"
    end
  end

  defp invocation_evidence(evidence) do
    Map.new(evidence, fn {key, value} -> {to_string(key), invocation_value(value)} end)
  end

  defp invocation_value(value) when is_atom(value), do: Atom.to_string(value)
  defp invocation_value(value), do: value

  @doc false
  def render_reviewer_prompt(intent, candidate_id, config) do
    "priv/kogen/prompts/reviewer.md"
    |> File.read!()
    |> String.replace("{{intent_title}}", intent.title)
    |> String.replace("{{intent_id}}", intent.id)
    |> String.replace("{{approved_path}}", Path.join(@approved_base, intent.slug))
    |> String.replace("{{candidate_id}}", candidate_id)
    |> String.replace("{{execution_policy}}", Kogen.ExecutionPolicy.render(config, "reviewer"))
  end
end
