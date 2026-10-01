# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Kogen.Build do
  @moduledoc """
  The synchronous Build loop: preconditions, one Developer launch,
  controller-owned verification after every Developer turn, a fresh Review,
  bounded Rework (at most `outer_resumptions` resumes of the exact Developer
  thread), and one ordinary Git Commit carrying the Intent identity.

  Each Build runs in its own Candidate worktree with its own harness home
  (`Kogen.Build.Workspace`), created at admission, before any launch. Every
  role launch, native helper, controller `make -C <Candidate>` run, Candidate
  id, changed path, guarded-path capture, proof selector, report, review
  packet, citation, staging and commit uses the Candidate root, passed
  explicitly. The build lock, tracking record, verification context, state,
  history and receipts, prompts, route and config and login-scope identity
  stay on the control root, passed explicitly; nothing reads the process
  working directory. Every role process tree runs inside one Build-wide
  macOS Seatbelt profile (`Kogen.Build.WriteBoundary`); the controller and
  its verification children stay outside it. Publication commits in the
  Candidate and fast-forwards the unmoved admitted branch in control; every
  other outcome keeps the Candidate and names it.

  After each Developer turn this controller (the code loaded when the Build
  started, never code from the Candidate) computes the Candidate id and runs
  exactly the approved `verified_by` targets itself
  (`Kogen.Build.Verification`). A failed cycle resumes the exact Developer
  session with the failed target's receipt and log paths, counting against
  `verification_retries` and never the outer allowance; exhaustion stops the
  Build before Jev and Review. No child process ever receives a verification
  or tracking context.

  After controller verification settles, controller code builds the handoff
  report (`Kogen.Build.Report`). The Developer's final message is free prose
  that no Kogen code parses: Build records it as unverified notes and asks
  TypeSafe Jev (`Kogen.Jev`) once what the Developer says about each item.
  Only a confident contract objection stops the Build, unless an earlier
  controller cycle of the same attempt failed and its final cycle passed on
  the settled Candidate: that objection is superseded and reaches the Reviewer
  as an advisory item. Every other reading, and any Jev failure, reaches the
  fresh Reviewer as advisory notes. Each Reviewer starts from one bounded
  review packet per attempt (`Kogen.Build.ReviewPacket`).
  """
  use Boundary,
    deps: [
      Kogen.Intent,
      Kogen.Harness,
      Kogen.Check,
      Kogen.Git,
      Kogen.VerificationPolicy,
      Kogen.ExecutionPolicy,
      Kogen.Jev,
      Kogen.ProcessCustody,
      Kogen.ProjectScope
    ],
    exports: [Workspace, WriteBoundary, VerificationPlan]

  alias Kogen.Build.{
    AcceptanceJoin,
    BaseWorkspace,
    Breakers,
    Continuation,
    Contract,
    FailureHandoff,
    FailureReport,
    FailureSignature,
    GuardedPaths,
    Ledger,
    Progress,
    Reconcile,
    Report,
    Review,
    ReviewPacket,
    TargetEvidence,
    Tracking,
    Verification,
    VerificationPlan,
    Workspace,
    WriteBoundary
  }

  alias Kogen.Harness.ProviderMarker

  require Logger

  # Removed from every Developer, Reviewer and target child, including when
  # this controller itself inherited one from an outer Build's Stop runner.
  @context_variables ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_TRACKING_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT)
  # Removed from every role launch, so a role's compile uses the Candidate's
  # own `deps/` and `_build/`, never control's.
  @mix_redirection ~w(MIX_BUILD_PATH MIX_DEPS_PATH MIX_EXS)

  @config_path ".kogen/config.yaml"
  @approved_base ".kogen/intents/approved"
  @approved_changed "Approved Intent changed during Build; stopped without publication"

  @complete_base ".kogen/intents/complete"
  # Every harness a Build role may use is ready before any launch; the Expert
  # may be consulted from the Developer's harness through `mix kogen.expert`.
  @build_roles [:developer, :reviewer, :expert]
  @capacity_backoff_minutes [1, 2, 4, 8, 15]
  @incomplete_continuations 1

  @doc "Bounded retry delays for explicit provider capacity markers."
  def capacity_backoff_minutes, do: @capacity_backoff_minutes

  @doc """
  Runs one Build of the Approved Intent `slug` on the named `route`, or on the
  configured `default_route` when `route` is `nil`, for the control checkout
  at `control` (a main worktree, passed explicitly; `mix kogen.build` is the
  only place that reads the process cwd to find it). Configuration is
  resolved exactly once, before any harness readiness or launch; every later
  launch, resumption, controller verification cycle and Review uses that
  frozen route.
  """
  @spec run(String.t(), String.t() | nil, Path.t()) :: :ok | {:error, String.t()}
  def run(slug, route, control) when is_binary(control) and control != "" do
    with {:ok, control} <- control_checkout(control) do
      case acquire_lock(control) do
        :ok ->
          try do
            with {:ok, admission} <- admission_preconditions(slug, route, control),
                 {:ok, breaker_state} <- environment_breaker(control, admission.config) do
              %{config: config, intent: intent, approved_entries: approved_entries} = admission
              IO.puts("Approved Intent package size: #{admission.approved_package_bytes} bytes")

              case Continuation.decide(control, slug, intent, config, approved_entries) do
                :none ->
                  do_build(admission, slug, intent, config, approved_entries, breaker_state, nil)

                {:ok, continuation} ->
                  do_build(
                    admission,
                    slug,
                    intent,
                    config,
                    approved_entries,
                    breaker_state,
                    continuation
                  )

                {:error, _reason} = error ->
                  error
              end
            else
              {:error, _reason} = error -> error
            end
          after
            release_lock(control)
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  def run(_slug, _route, control),
    do: {:error, "Build requires an explicit control checkout root, got: #{inspect(control)}"}

  @doc """
  The admission preconditions every entry shares (the automatic loop): terminal-move recovery and reconciliation,
  the returned-Draft refusal, the route resolved once from control's config,
  the Approved package read, a clean control checkout
  without Candidate-blinding index flags, no Complete package, the Jev key and
  the write-boundary admission mode. The caller holds the build lock.
  """
  @spec admission_preconditions(String.t(), String.t() | nil, Path.t()) ::
          {:ok, map()} | {:error, String.t()}
  def admission_preconditions(slug, route, control) do
    with :ok <- recover_terminal_moves(control),
         :ok <- Reconcile.run(control),
         :ok <- recover_terminal_moves(control),
         :ok <- returned_draft_refusal(control, slug),
         {:ok, config} <- Kogen.Intent.read_config(Path.join(control, @config_path), route),
         {:ok, intent} <- Kogen.Intent.read(slug, Path.join(control, @approved_base)),
         {:ok, approved_entries} <- read_approved_entries(control, slug),
         :ok <- Kogen.Git.reject_candidate_blinding_index_flags(control),
         :ok <- check_clean_worktree(control),
         {:ok, branch} <- Kogen.Git.current_branch(control),
         {:ok, commit} <- Kogen.Git.head_sha(control),
         :ok <- check_complete_absent(control, slug),
         :ok <- Kogen.Jev.key_present(),
         {:ok, boundary_mode} <- WriteBoundary.admission_mode() do
      {:ok,
       %{
         control: control,
         branch: branch,
         commit: commit,
         boundary: boundary_mode,
         config: config,
         intent: intent,
         approved_entries: approved_entries,
         approved_package_bytes:
           Enum.reduce(approved_entries, 0, fn
             {_path, :regular, _mode, bytes}, total -> total + byte_size(bytes)
             _entry, total -> total
           end)
       }}
    end
  end

  @doc "The canonical main-worktree control root, or a refusal."
  @spec control_root(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def control_root(control), do: control_checkout(control)

  # The control root must be an existing main worktree (never a linked one,
  # such as a Candidate), named by its canonical path.
  defp control_checkout(control) do
    expanded = Path.expand(control)

    with true <- File.dir?(expanded),
         {:ok, top} <- git_in(expanded, ["rev-parse", "--show-toplevel"]),
         {:ok, git_dir} <- git_in(expanded, ["rev-parse", "--path-format=absolute", "--git-dir"]),
         {:ok, common} <-
           git_in(expanded, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         canonical = Workspace.canonical(expanded),
         true <- Workspace.canonical(top) == canonical do
      if Workspace.canonical(git_dir) == Workspace.canonical(common),
        do: {:ok, canonical},
        else:
          {:error,
           "Build control root must be a main worktree, not a linked worktree: #{expanded}"}
    else
      _ -> {:error, "Build control root is not a Git checkout root: #{expanded}"}
    end
  end

  defp git_in(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  # Approved inputs are ignored by Git. Keep their actual entries and bytes
  # in this Build's memory so provider/check edits cannot become approval.
  defp read_approved_entries(root, slug) do
    {:ok, package_entries(Path.join([root, @approved_base, slug]), "")}
  rescue
    error in File.Error ->
      {:error, "could not read Approved Intent: #{Exception.message(error)}"}
  end

  # A controller can exit between publishing its terminal report and moving
  # the package. The report and still-running owner are sufficient to finish
  # that single move before a new Build can be admitted.
  defp recover_terminal_moves(control) do
    Workspace.list(control)
    |> Enum.reduce_while(:ok, fn
      {:ok, %{"status" => status} = owner}, :ok
      when status == "running" or status == "stopped: interrupted" ->
        id = owner["tracking_build_id"] || owner["build_id"]
        report = FailureReport.report_path(control, id)

        if File.regular?(report) do
          with {:ok, bytes} <- File.read(report),
               {:ok, %{"category" => category} = failure} <- Jason.decode(bytes),
               :ok <- FailureReport.return_to_draft(control, report),
               :ok <- settle_recovered_owner(control, owner, category, failure) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
            _ -> {:halt, {:error, "package custody: invalid recovered report"}}
          end
        else
          {:cont, :ok}
        end

      _owner, :ok ->
        {:cont, :ok}
    end)
  end

  defp settle_recovered_owner(control, owner, category, failure) do
    if is_map(failure["candidate"]) and failure["continuable"] != true and
         failure["published"] != true,
       do:
         Workspace.set_owner_status(
           control,
           owner["build_id"],
           "stopped: #{category}"
         ),
       else: :ok
  end

  defp returned_draft_refusal(control, slug) do
    approved = Path.join([control, @approved_base, slug])
    draft = Path.join([control, ".kogen/intents/drafts", slug])

    if not File.dir?(approved) and File.dir?(draft),
      do:
        {:error,
         "terminal failed Build returned #{slug} to Draft; reconcile and explicitly reapprove it before another Build"},
      else: :ok
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

  # Control's package and the Candidate's copy must both still be the frozen
  # bytes; the controller's memory remains the authority. Outside a Developer
  # handoff any change, an added entry included, is an integrity stop.
  defp approved_unchanged(ctx) do
    case approved_state(ctx) do
      :ok -> :ok
      _changed -> {:error, @approved_changed}
    end
  end

  # At a Developer handoff, entries ADDED to the Candidate's copy (and nothing
  # else) are `{:added, paths}`: Candidate-relative leaf paths the Developer
  # is made to delete. A modified or deleted entry, or any change to control's
  # package, stays an integrity stop.
  defp approved_state(ctx) do
    with {:ok, entries} when entries == ctx.approved_entries <-
           read_approved_entries(ctx.control, ctx.slug),
         {:ok, entries} <- read_approved_entries(ctx.root, ctx.slug),
         frozen = Map.new(ctx.approved_entries, &{elem(&1, 0), &1}),
         current = Map.new(entries, &{elem(&1, 0), &1}),
         true <- Enum.all?(frozen, fn {path, entry} -> current[path] == entry end) do
      case current |> Map.keys() |> Enum.reject(&Map.has_key?(frozen, &1)) |> leaves() do
        [] -> :ok
        added -> {:added, Enum.map(added, &Path.join([@approved_base, ctx.slug, &1]))}
      end
    else
      _ -> {:error, @approved_changed}
    end
  end

  # Added entries with no added entry below them.
  defp leaves(paths),
    do: Enum.reject(paths, fn path -> Enum.any?(paths, &String.starts_with?(&1, path <> "/")) end)

  defp check_complete_absent(root, slug) do
    path = Path.join([root, @complete_base, slug])

    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        {:error, "Complete Intent already exists: #{slug}"}

      {:error, reason} ->
        {:error, "could not inspect Complete Intent #{slug}: #{inspect(reason)}"}
    end
  end

  defp check_clean_worktree(control) do
    if Kogen.Git.clean_worktree?(control) do
      :ok
    else
      {:error, "worktree is not clean (git status --porcelain is non-empty)"}
    end
  end

  # The lock names this OS process's pid and start time (and, once admitted,
  # the build id and every launched group's pid/pgid/start time), so the
  # Candidate commands can tell a live Build from a stale record, and a later
  # Build can reap an abandoned one (`Kogen.ProcessCustody`).
  defp acquire_lock(control) do
    case Kogen.ProcessCustody.acquire(control) do
      {:ok, _fresh_or_reclaimed} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp claim_lock(control, build_id), do: Kogen.ProcessCustody.claim(control, build_id)

  defp release_lock(control), do: Kogen.ProcessCustody.release(control)

  defp environment_breaker(control, config) do
    state = Breakers.environment_state(control)
    maybe_probe_environment(state, config, control)
  end

  defp maybe_probe_environment(%{tripped: false} = state, _config, _control),
    do: {:ok, Map.put(state, :readiness, :not_run)}

  defp maybe_probe_environment(%{tripped: true, run: run} = state, config, control) do
    case Kogen.Harness.open_roles(config, @build_roles, control) do
      {:ok, runtime} ->
        Kogen.Harness.close(runtime)
        {:ok, Map.put(state, :readiness, :passed)}

      {:error, reason} ->
        {:error, Breakers.readiness_refusal_message(run, reason)}
    end
  end

  defp maybe_write_readiness_clear(_tracking, %{readiness: readiness}) when readiness != :passed,
    do: :ok

  defp maybe_write_readiness_clear(tracking, %{run: run}) do
    Breakers.write_clear(tracking.path, "readiness", run)
  end

  @doc "Environment entries that remove every verification or tracking context from a child."
  def context_scrub, do: Enum.map(@context_variables, &{&1, nil})

  # The static, unchanging-for-the-whole-Build inputs, bundled so the
  # settle/review/rework chain below stays under a sane arity as it
  # threads per-attempt state (candidate id, session id, resumption count,
  # Check record, target results) through the loop.
  defp do_build(admission, slug, intent, config, approved_entries, breaker_state, continuation) do
    with {:ok, inputs} <- run_inputs(admission.control, slug, intent, config),
         {:ok, tracking} <-
           Tracking.new(
             intent,
             inputs.contract,
             approved_entries,
             config,
             admission.control,
             continuation_link(continuation)
           ) do
      _ = maybe_write_readiness_clear(tracking, breaker_state)

      admission
      |> Map.merge(%{
        slug: slug,
        intent: intent,
        config: config,
        approved_entries: approved_entries
      })
      |> base_context(inputs, tracking, continuation)
      |> admit_candidate(admission)
    end
  end

  @doc """
  Shared run inputs read from control once per controller process: the
  Approved contract, the verification catalog and plan and the credential
  bindings of every role the plan needs.
  """
  @spec run_inputs(Path.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def run_inputs(control, slug, intent, config) do
    added = added_targets(intent)

    with {:ok, contract} <- Contract.load(Path.join([control, @approved_base, slug]), control),
         {:ok, catalog} <- VerificationPlan.load(control),
         {:ok, plan} <-
           VerificationPlan.build(
             contract.scenarios,
             intent.may_change_guarded_paths,
             catalog,
             control,
             added: added
           ),
         {:ok, bindings} <-
           Kogen.Harness.bindings(config, Enum.uniq(@build_roles ++ plan.login_roles), control) do
      {:ok,
       %{
         contract: contract,
         catalog: catalog,
         plan: plan,
         bindings: bindings,
         guard_targets: catalog_guard_targets(added).(catalog)
       }}
    end
  end

  @doc "The controller context of one admitted run, before its Candidate opens."
  @spec base_context(map(), map(), map(), map() | nil) :: map()
  def base_context(admission, inputs, tracking, continuation) do
    %{
      slug: admission.slug,
      intent: admission.intent,
      config: admission.config,
      contract: inputs.contract,
      targets: inputs.plan.targets,
      plan: inputs.plan,
      catalog: inputs.catalog,
      base_commit: admission.commit,
      workspace: nil,
      guarded_snapshot: nil,
      policy_environment: nil,
      approved_entries: admission.approved_entries,
      tracking: tracking,
      token: nil,
      reviewers: [],
      references: %{},
      review_packet: nil,
      runtime: nil,
      control: admission.control,
      root: nil,
      candidate: nil,
      boundary: nil,
      bindings: inputs.bindings,
      login_roles: inputs.plan.login_roles,
      guard_targets: inputs.guard_targets,
      continuation: continuation,
      continuation_resume_pending: not is_nil(continuation),
      capacity_retry_count: 0,
      provisional: nil,
      span_started_ms: System.os_time(:millisecond),
      progress: initial_progress(admission.config, continuation || %{record: tracking.record})
    }
  end

  # Progress limits are frozen at admission; a continuation carries the
  # spent counters forward from its record instead of resetting them.
  defp initial_progress(config, %{record: record}) do
    recorded =
      record
      |> Map.get("attempts", [])
      |> List.wrap()
      |> Enum.reverse()
      |> Enum.find_value(& &1["progress"])

    case recorded && Progress.from_map(recorded) do
      {:ok, state} -> state
      _ -> initial_progress(config, nil)
    end
  end

  defp initial_progress(config, _continuation) do
    case Progress.new_from_config(config) do
      {:ok, state} -> state
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp continuation_link(nil), do: nil

  defp continuation_link(%{id: id, report: report}),
    do: %{
      "build_id" => id,
      "record_sha256" => report["record_sha256"],
      "category" => report["category"]
    }

  # One Candidate and one harness home per Build, created before any launch.
  # The build id is the tracking record id.
  defp admit_candidate(ctx, admission) do
    build_id = ctx.tracking.path |> Path.dirname() |> Path.basename()
    owner_id = if ctx.continuation, do: ctx.continuation.owner["build_id"], else: build_id
    claim_lock(ctx.control, owner_id)

    workspace =
      case ctx.continuation do
        nil ->
          Workspace.create(
            %{
              control: ctx.control,
              slug: ctx.slug,
              build_id: build_id,
              intent_id: ctx.intent.id,
              title: ctx.intent.title,
              branch: admission.branch,
              commit: admission.commit,
              bindings: binding_records(ctx.bindings)
            },
            ctx.approved_entries
          )

        continuation ->
          with {:ok, candidate} <- Workspace.adopt(continuation.owner, ctx.approved_entries),
               candidate = %{candidate | tracking_build_id: build_id},
               :ok <- Workspace.update_status(candidate, "running") do
            {:ok, candidate}
          end
      end

    case workspace do
      {:ok, candidate} ->
        ctx = %{ctx | candidate: candidate, root: candidate.path}

        try do
          run_in_candidate(ctx, admission)
        after
          Workspace.copy_raw_log(candidate)
          Workspace.remove_temp_dir(candidate)
        end

      {:error, reason} ->
        record_failure(ctx, "Candidate admission refused before any launch: #{reason}")
    end
  end

  defp record_failure(ctx, reason) do
    record =
      ctx.tracking.record
      |> Map.put("status", "failed")
      |> Map.put("admission_failure", reason)

    case Tracking.update(ctx.tracking, record) do
      {:ok, tracking} ->
        ctx = %{ctx | tracking: tracking}
        report = FailureReport.record_failure(ctx, "admission", reason)
        suffix = report_suffix(report, "admission", ctx.tracking.path)
        {:error, "#{reason}; tracking record: #{ctx.tracking.path}#{suffix}"}

      {:error, error} ->
        {:error,
         "#{reason}; tracking persistence/integrity failure: #{error}; tracking record: #{ctx.tracking.path}"}
    end
  end

  # Boundary, readiness and base workspace, in that order: a boundary that
  # cannot be applied stops before any readiness call, and readiness runs
  # with the Build's own launch environment inside the boundary.
  defp run_in_candidate(ctx, admission) do
    case open_candidate_context(ctx, admission.boundary) do
      {:ok, ctx} ->
        runtime = ctx.runtime

        try do
          {session_id, number, reason} = continuation_attempt(ctx)
          begin_attempt(ctx, session_id, number, reason)
        after
          Kogen.Harness.close(runtime)
          BaseWorkspace.remove(Process.delete(:kogen_base_workspace) || ctx.workspace)
        end

      # The latest context is kept, so the stop records what admission
      # reached (the boundary block) and removes what it created.
      {:error, ctx, reason} ->
        BaseWorkspace.remove(ctx.workspace)

        details =
          if readiness_reason?(reason),
            do: %{"stop_category" => "environment"},
            else: %{}

        stop(ctx, reason, details)
    end
  end

  @doc """
  Opens a run's Candidate for a controller process, in the one order every
  entry uses: the write boundary, the recorded Candidate block, the policy
  preflight, the guarded-path capture, the base workspace and role readiness
  (inside the boundary, with exactly the recorded credential bindings); then
  the role matrix frozen in the record replaces the configured one.
  """
  @spec open_candidate_context(map(), term()) :: {:ok, map()} | {:error, map(), term()}
  def open_candidate_context(ctx, boundary_mode) do
    steps = [
      &apply_boundary(&1, boundary_mode),
      &record_candidate(&1, "running", nil),
      &preflight_candidate/1,
      &capture_candidate/1,
      &admit_base_workspace/1,
      &open_roles/1
    ]

    case Enum.reduce_while(steps, {:ok, ctx}, &admission_step/2) do
      {:ok, ctx} ->
        config = assigned_config(ctx.config, ctx.tracking.record)

        {:ok,
         %{
           ctx
           | config: config,
             runtime: %{ctx.runtime | route: config},
             policy_environment: Kogen.VerificationPolicy.environment(ctx.guard_targets, ctx.root)
         }}

      {:error, ctx, reason} ->
        {:error, ctx, reason}
    end
  end

  @doc "Closes what `open_candidate_context/2` opened."
  def close_candidate_context(ctx) do
    if ctx[:runtime], do: Kogen.Harness.close(ctx.runtime)
    BaseWorkspace.remove(Process.delete(:kogen_base_workspace) || ctx[:workspace])
    :ok
  end

  defp continuation_attempt(%{continuation: nil}), do: {nil, 0, nil}

  defp continuation_attempt(%{continuation: %{record: record, report: report}}) do
    attempt = List.last(record["attempts"] || []) || %{}

    # Guard reworks spend the outer allowance inside one attempt; a
    # continuation resumes at the count already spent, never afresh.
    spent = max(attempt["number"] || 0, attempt["guard_resumptions_spent"] || 0)

    {report["developer_session_id"] || attempt["developer_session_id"], spent, :continuation}
  end

  defp admission_step(step, {:ok, ctx}) do
    case step.(ctx) do
      {:ok, ctx} -> {:cont, {:ok, ctx}}
      {:error, reason} -> {:halt, {:error, ctx, reason}}
    end
  end

  defp readiness_reason?(reason) when is_binary(reason),
    do: String.contains?(reason, " harness ") and String.contains?(reason, " is not ready")

  defp readiness_reason?(_), do: false

  defp apply_boundary(ctx, mode) do
    with {:ok, boundary} <- boundary(mode, ctx), do: {:ok, %{ctx | boundary: boundary}}
  end

  defp preflight_candidate(ctx) do
    with :ok <- Kogen.VerificationPolicy.preflight(ctx.guard_targets, ctx.root), do: {:ok, ctx}
  end

  defp capture_candidate(ctx) do
    with {:ok, snapshot} <- GuardedPaths.capture(ctx.root),
         do: {:ok, %{ctx | guarded_snapshot: snapshot}}
  end

  defp admit_base_workspace(ctx) do
    with {:ok, workspace} <- base_workspace(ctx.catalog, ctx.control, ctx.base_commit),
         do: {:ok, %{ctx | workspace: workspace}}
  end

  defp boundary(:apply, ctx) do
    WriteBoundary.prepare(boundary_input(ctx))
  end

  defp boundary({:inherited, sha256}, ctx) do
    {:ok, WriteBoundary.inherited(sha256, boundary_input(ctx))}
  end

  defp boundary_input(ctx) do
    candidate = ctx.candidate

    %{
      candidate: candidate.path,
      harness_home: candidate.harness_home,
      tmp_dir: candidate.tmp_dir,
      control: ctx.control,
      claude_scope: scope_grant(ctx.bindings["claude"]),
      codex_scope: scope_grant(ctx.bindings["codex"])
    }
  end

  # A scope that does not exist yet has nothing a role could write; readiness
  # then refuses the missing login.
  defp scope_grant(%{scope: %{path: path}}) do
    if File.dir?(path), do: path
  end

  defp scope_grant(_binding), do: nil

  # The launch every role of this Build uses: the Candidate as cwd, the
  # harness home, the boundary's argv prefix and environment, and each
  # harness's login binding resolved once from control at admission.
  defp launch(ctx) do
    boundary = ctx.boundary
    input = boundary_input(ctx)

    %{
      root: ctx.root,
      control: ctx.control,
      harness_home: ctx.candidate.harness_home,
      tmp_dir: ctx.candidate.tmp_dir,
      prefix: WriteBoundary.prefix(boundary),
      env:
        WriteBoundary.environment(boundary) ++
          [{"KOGEN_HARNESS_HOME", ctx.candidate.harness_home}] ++
          project_mise_path() ++
          Enum.map(@mix_redirection, &{&1, nil}),
      bindings: ctx.bindings,
      boundary:
        input
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(%{"mode" => boundary.mode, "sha256" => boundary.sha256})
    }
  end

  defp project_mise_path do
    data =
      System.get_env("MISE_DATA_DIR") ||
        Path.join([System.user_home!(), ".local", "share", "mise"])

    shims = Path.join(data, "shims")

    if File.dir?(shims), do: [{"PATH", shims <> ":" <> System.get_env("PATH", "")}], else: []
  end

  defp added_targets(intent) do
    case Map.get(intent, :catalog_changes) do
      %{add: add} when is_list(add) -> add
      _ -> []
    end
  end

  # The Bash gate guard blocks `make <goal>` for every catalog target and
  # every declared addition; no target name is special.
  defp catalog_guard_targets(added), do: &Enum.uniq(&1.ordered_targets ++ added)

  # Built at admission, outside the repository, from control's object store at
  # the admission commit, only when the admission catalog declares the
  # integrity fields.
  defp base_workspace(%{integrity: nil}, _control, _commit), do: {:ok, nil}

  defp base_workspace(%{integrity: integrity}, control, commit),
    do: BaseWorkspace.create(control, commit, integrity["base_cache"])

  # The owner record names the Build's credential bindings from its first
  # write, before any harness process starts. Readiness of every role harness
  # then runs inside the boundary with exactly those recorded bindings.
  defp open_roles(ctx) do
    with :ok <- recorded_bindings(ctx),
         {:ok, runtime} <-
           Kogen.Harness.open_roles(
             ctx.config,
             Enum.uniq(@build_roles ++ ctx.login_roles),
             ctx.control,
             launch(ctx)
           ) do
      {:ok, %{ctx | runtime: runtime}}
    end
  end

  defp recorded_bindings(ctx) do
    expected = binding_records(ctx.bindings)

    case Workspace.recorded_bindings(ctx.candidate) do
      {:ok, [_ | _] = ^expected} ->
        :ok

      {:ok, _recorded} ->
        {:error,
         "Candidate owner record #{ctx.candidate.owner_path} does not name the Build's credential bindings"}

      {:error, _reason} = error ->
        error
    end
  end

  defp binding_records(bindings) do
    bindings
    |> Enum.sort()
    |> Enum.map(fn {_harness, binding} -> Kogen.Harness.binding_record(binding) end)
  end

  defp begin_attempt(ctx, session_id, number, reason) do
    case open_attempt(ctx, session_id, number, %{}) do
      {:ok, ctx} -> launch_attempt(ctx, session_id, number, reason)
      {:error, ctx, error} -> stop(ctx, error)
    end
  end

  @doc """
  Opens one attempt: atomically appends its current progress checkpoint and
  `extra` fields to the tracking record, then initializes its controller
  verification context. It launches nothing.
  """
  @spec open_attempt(map(), String.t() | nil, non_neg_integer(), map()) ::
          {:ok, map()} | {:error, map(), String.t()}
  def open_attempt(ctx, session_id, number, extra) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    attempt =
      Map.merge(extra, %{
        "attempt_token" => token,
        "number" => number,
        "status" => "pending",
        "developer_session_id" => session_id
      })

    attempt =
      case ctx.continuation do
        %{record: record} ->
          previous = List.last(record["attempts"] || []) || %{}
          Map.put(attempt, "guard_violations", List.wrap(previous["guard_violations"]))

        _ ->
          attempt
      end

    attempt =
      if is_map(ctx.progress),
        do: Map.put(attempt, "progress", Progress.to_map(ctx.progress)),
        else: attempt

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
                 retry_budgets(ctx.config, ctx.continuation),
                 ctx.plan,
                 verification_roots(ctx)
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
                   "file" => "context.json",
                   "sha256" => execution.context_sha256,
                   "content_base64" => Base.encode64(execution.context_bytes)
                 }
               }) do
            {:ok, ctx} -> {:ok, ctx}
            {:error, error} -> {:error, ctx, error}
          end
        else
          {:error, error} -> {:error, %{ctx | tracking: tracking}, error}
        end

      {:error, reason} ->
        {:error, ctx, reason}
    end
  end

  # The local Verification Record and its history are archived and reset only
  # here, once per outer attempt, never between verification cycles.
  defp launch_attempt(ctx, session_id, number, reason) do
    with :ok <- inputs_unchanged(ctx),
         :ok <- Kogen.VerificationPolicy.preflight(ctx.catalog.ordered_targets, ctx.root),
         :ok <- invalidate_verification_record(ctx.control) do
      launch_developer(ctx, session_id, number, reason)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp launch_developer(ctx, session_id, number, reason) do
    prompt = developer_prompt(ctx, reason)

    ctx =
      Map.merge(ctx, %{
        developer_prompt: prompt,
        provider_retried: false,
        provider_retry_count: 0,
        guard_rework_notes: []
      })

    result =
      if session_id do
        resume_developer(ctx, session_id, prompt)
      else
        Kogen.Harness.launch_build_developer(
          prompt,
          ctx.config.developer.model,
          ctx.config.developer.effort,
          developer_environment(ctx),
          developer_context(ctx)
        )
      end

    receive_developer(ctx, session_id, number, result)
  end

  # Clears control's local Verification Record before each outer attempt,
  # preserving prior history in the private raw-log directory when one is
  # requested, as `Kogen.Check.invalidate!/0` does for its own checkout.
  defp invalidate_verification_record(control) do
    history = Path.join(control, Kogen.Check.history_path())

    with :ok <- archive_verification_history(history),
         :ok <- remove_stale(Path.join(control, Kogen.Check.record_path()), "Verification Record") do
      remove_stale(history, "Verification Record history")
    end
  end

  defp archive_verification_history(history) do
    case {System.get_env("KOGEN_RAW_LOG_DIR"), File.read(history)} do
      {dir, {:ok, bytes}} when is_binary(dir) and byte_size(bytes) > 0 ->
        name =
          "verification-history-#{System.pid()}-#{:erlang.unique_integer([:positive, :monotonic])}.jsonl"

        with :ok <- File.mkdir_p(dir), :ok <- File.write(Path.join(dir, name), bytes) do
          :ok
        else
          {:error, reason} ->
            {:error,
             "could not archive Verification Record history: #{:file.format_error(reason)}"}
        end

      _ ->
        :ok
    end
  end

  defp remove_stale(path, label) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "could not clear stale #{label}: #{:file.format_error(reason)}"}
    end
  end

  defp resume_developer(ctx, session_id, prompt) do
    Kogen.Harness.resume_build_developer(
      session_id,
      prompt,
      ctx.config.developer.model,
      ctx.config.developer.effort,
      developer_environment(ctx),
      developer_context(ctx)
    )
  end

  # A Developer never receives a verification context: the policy guard's
  # immutable inputs only, with every inherited context removed.
  defp developer_environment(ctx), do: ctx.policy_environment ++ context_scrub()

  # Only the Developer launch carries the turn time-box (`:turn_timeout_ms`);
  # the harness adapters apply it as a soft timeout (TERM, grace, KILL) so the
  # session stays resumable. Reviewer, Expert, Shaper and verification launches
  # never receive it.
  defp developer_context(ctx) do
    context = scrubbed_context(ctx, :developer)

    Map.put(context, :turn_timeout_ms, developer_turn_timeout_ms(ctx.config))
  end

  @default_developer_turn_minutes 30

  @doc false
  # The nudge interval of one Developer turn: when a turn runs this long it is
  # interrupted softly and resumed with a nudge; never a stop. The turn is not
  # clamped to any Build time.
  @spec developer_turn_timeout_ms(map()) :: pos_integer()
  def developer_turn_timeout_ms(config) do
    (Map.get(config, :developer_turn_minutes) || @default_developer_turn_minutes) * 60_000
  end

  defp scrubbed_context(ctx, role) do
    context = Kogen.Harness.role_context(ctx.runtime, role)
    %{context | env: context.env ++ context_scrub()}
  end

  defp receive_developer(ctx, expected, number, {:ok, turn}) do
    if expected && turn.session_id != expected do
      stop(
        ctx,
        "resume created a new session (expected #{expected}, got #{turn.session_id})",
        %{
          "stop_category" =>
            if(continuation_resume_pending?(ctx),
              do: "session-lost",
              else: "provider-failure"
            ),
          "developer_session_id" => turn.session_id,
          "developer_notes" => notes_record(turn.message),
          "developer_invocation" => invocation_evidence(turn.invocation_evidence)
        }
      )
    else
      ctx =
        ctx
        |> mark_continuation_resumed()
        |> Map.merge(%{incomplete_turn_count: 0, turn_nudge_count: 0})

      notes = Map.fetch!(turn, :message)
      invocation = invocation_evidence(turn.invocation_evidence)

      verify_turn(ctx, turn.session_id, number, notes, invocation)
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
        "stop_category" =>
          if(continuation_resume_pending?(ctx),
            do: "session-lost",
            else: "provider-failure"
          ),
        "developer_session_id" => session_id,
        "developer_invocation" => invocation_evidence(evidence)
      })
    else
      settle_transport_failure(mark_continuation_resumed(ctx), number, reason, evidence)
    end
  end

  defp receive_developer(
         ctx,
         expected,
         number,
         {:error, {:developer_turn_timeout, evidence}}
       ) do
    session_id = evidence[:session_id]

    case post_developer_inputs_unchanged(ctx) do
      {:ok, ctx} when is_binary(expected) and is_binary(session_id) and session_id != expected ->
        stop(ctx, "resume created a new session (expected #{expected}, got #{session_id})", %{
          "stop_category" => "provider-failure",
          "developer_session_id" => session_id,
          "developer_invocation" => invocation_evidence(evidence)
        })

      {:ok, ctx} ->
        settle_turn_timeout(mark_continuation_resumed(ctx), number, session_id, evidence)

      {violation, ctx} ->
        stop(ctx, failed_turn_violation(violation), %{
          "developer_invocation" => invocation_evidence(evidence),
          "stop_category" => "integrity"
        })
    end
  end

  defp receive_developer(ctx, _expected, _number, {:error, reason}) do
    case post_developer_inputs_unchanged(ctx) do
      {:ok, ctx} ->
        stop(
          ctx,
          "harness failure during Developer turn: #{inspect(reason)} #{role_label(ctx, :developer)}"
        )

      {violation, ctx} ->
        stop(ctx, failed_turn_violation(violation), %{"stop_category" => "integrity"})
    end
  end

  defp continuation_resume_pending?(%{continuation: continuation} = ctx)
       when is_map(continuation),
       do: Map.get(ctx, :continuation_resume_pending, false)

  defp continuation_resume_pending?(_ctx), do: false

  defp mark_continuation_resumed(%{continuation: continuation} = ctx) when is_map(continuation),
    do: Map.put(ctx, :continuation_resume_pending, false)

  defp mark_continuation_resumed(ctx), do: ctx

  # After every Developer turn this controller settles what needs no
  # verification first: Jev reads the turn's notes once, a confident
  # objection that no later cycle could supersede stops the Build as
  # `cannot_comply`, and a missing declared proof selector returns the
  # Developer as `unfinished_work`, neither running nor counting a cycle. A
  # Candidate id unchanged since a failed cycle stops rather than re-running
  # it. Only then does the controller verify the Candidate itself. A failed
  # cycle with its class's retries left resumes the exact Developer session;
  # it never consumes the outer allowance and never reaches Review.
  #
  # First the guard: protected paths and frozen approval inputs stop or
  # rework before a cycle. Ordinary extra paths are retained with their
  # actual hunks for the fresh Reviewer.
  defp verify_turn(ctx, session_id, number, notes, invocation) do
    ctx = observe_turn(ctx)

    case time_gate(ctx, "verification") do
      {:ok, ctx} -> verify_turn_with_inputs(ctx, session_id, number, notes, invocation)
      {:stop, result} -> result
    end
  end

  defp time_gate(ctx, boundary) do
    case note_time(ctx, boundary) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:stop, stop(ctx, reason)}
    end
  end

  defp verify_turn_with_inputs(ctx, session_id, number, notes, invocation) do
    case post_developer_inputs_unchanged(ctx) do
      {:ok, ctx} ->
        {notes, ctx} = guarded_notes(ctx, notes)
        verify_guarded_turn(ctx, session_id, number, notes, invocation)

      {{:rework, paths}, ctx} ->
        guard_rework(ctx, session_id, number, notes, invocation, paths)

      {{:stop, category, message}, ctx} ->
        stop(ctx, message, %{"stop_category" => category})
    end
  end

  # A Developer repair may legitimately produce a new Candidate
  # revision. Keep its prior citation bytes as immutable history, while
  # dropping only the old revision's mutable source-file guards. The next
  # handoff snapshots and binds any citations it still uses.
  defp rebind_candidate_references(ctx) do
    attempt = current_attempt(ctx)
    previous_candidate = attempt["candidate_id"]

    if is_binary(previous_candidate) do
      case Kogen.Git.candidate_id(ctx.root) do
        {:ok, ^previous_candidate} ->
          {:ok, ctx}

        {:ok, candidate_id} ->
          case mutable_reference_paths(ctx, previous_candidate) do
            {:ok, paths} ->
              candidate_references = Map.take(ctx.references, paths)
              active_references = Map.drop(ctx.references, paths)
              reviewer_references = attempt["reviewer_reference_snapshots"] || %{}
              retained_reviewer = Map.drop(reviewer_references, paths)

              history =
                attempt["reference_snapshot_history"]
                |> List.wrap()
                |> archive_references(previous_candidate, candidate_references)

              # Tracking requires the exact prior Reviewer map when replacing it.
              # Retire its source entries now, under their actual revision, so a
              # fresh Review cannot later archive old bytes under the repaired id.
              history =
                if reviewer_references == retained_reviewer,
                  do: history,
                  else: archive_references(history, previous_candidate, reviewer_references)

              changes =
                Map.merge(supersede_packet(attempt), %{
                  "candidate_id" => candidate_id,
                  "reference_snapshot_history" => history,
                  "reference_snapshots" => active_references,
                  "reviewer_reference_snapshots" => retained_reviewer
                })

              case record_attempt(ctx, changes) do
                {:ok, ctx} ->
                  {:ok, %{ctx | references: active_references, review_packet: nil}}

                {:error, reason} ->
                  {:error, ctx, reason}
              end

            {:error, reason} ->
              {:error, ctx, reason}
          end

        {:error, reason} ->
          {:error, ctx, "could not bind Candidate revision before citation rebind: #{reason}"}
      end
    else
      {:ok, ctx}
    end
  end

  defp archive_references(history, _candidate_id, snapshots) when map_size(snapshots) == 0,
    do: history

  defp archive_references(history, candidate_id, snapshots) do
    entry = %{"candidate_id" => candidate_id, "snapshots" => snapshots}
    if entry in history, do: history, else: history ++ [entry]
  end

  # Use the cited revision's tree, rather than today's ignore rules or file
  # existence: new source files and deleted source files can both be repaired.
  # Ignored evidence and controller/Approved inputs never become mutable just
  # because a source repair changed the tree.
  defp mutable_reference_paths(ctx, candidate_id) do
    case System.cmd("git", ["ls-tree", "-r", "--name-only", "-z", candidate_id],
           cd: ctx.root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        paths =
          output
          |> String.split(<<0>>, trim: true)
          |> Enum.reject(fn path ->
            Map.has_key?(ctx.guarded_snapshot.ignored, path) or
              path == Tracking.relative_path(ctx.tracking) or
              String.starts_with?(path, ".kogen/runtime/") or
              String.starts_with?(path, @approved_base <> "/")
          end)

        {:ok, paths}

      {output, _code} ->
        {:error, "could not identify mutable Candidate citations: #{String.trim(output)}"}
    end
  end

  # The notes of each turn that ended in a guard rework, followed by this
  # turn's, each under a controller header, are the verified turn's notes;
  # every existing notes path (Jev, record, packet, cannot_comply) carries
  # the combined text.
  defp guarded_notes(ctx, notes) do
    case ctx[:guard_rework_notes] || [] do
      [] ->
        {notes, ctx}

      kept ->
        parts =
          Enum.map(kept, fn {k, text} ->
            "[Developer notes, turn that ended in guard rework #{k}]\n#{text}"
          end) ++ ["[Developer notes, turn that passed the guard]\n#{notes}"]

        {Enum.join(parts, "\n\n"), Map.put(ctx, :guard_rework_notes, [])}
    end
  end

  defp guard_rework(ctx, session_id, number, notes, invocation, paths) do
    items = GuardedPaths.rework_items(ctx.guarded_snapshot, paths, guard_list(ctx))
    listed = Enum.map(items, &elem(&1, 0))
    previous = List.wrap(current_attempt(ctx)["guard_violations"])

    entry = %{
      "cycle" => length(ctx.execution.state["cycles"] || []),
      "paths" => listed,
      "developer_notes" => notes_record(notes)
    }

    case record_attempt(ctx, %{
           "guard_violations" => previous ++ [entry],
           "guard_resumptions_spent" => number + 1,
           "developer_session_id" => session_id,
           "developer_invocation" => invocation
         }) do
      {:ok, ctx} when number >= ctx.config.outer_resumptions ->
        stop(ctx, GuardedPaths.violation_message(paths), %{
          "stop_category" => "guard-violation"
        })

      {:ok, ctx} ->
        kept = (ctx[:guard_rework_notes] || []) ++ [{length(previous) + 1, notes_text(notes)}]
        prompt = guard_rework_prompt(ctx, items, ctx.config.outer_resumptions - number - 1)

        ctx =
          Map.merge(ctx, %{
            developer_prompt: prompt,
            provider_retried: false,
            guard_rework_notes: kept
          })

        receive_developer(
          ctx,
          session_id,
          number + 1,
          resume_developer(ctx, session_id, prompt)
        )

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  defp guard_list(ctx), do: ctx.intent.may_change_guarded_paths

  defp notes_text(notes) when is_binary(notes), do: notes
  defp notes_text(_notes), do: ""

  defp guard_rework_prompt(ctx, items, left) do
    lines =
      Enum.map(items, fn
        {path, :delete} ->
          "- delete: `#{path}`"

        {path, {:restore, mode}} ->
          quoted = shell_quote(path)
          "- restore: `git show HEAD:#{quoted} > #{quoted} && chmod #{mode} #{quoted}`"
      end)

    """
    Guard rework required after your turn: the Candidate added entries to the frozen Approved package. The controller ran no verification for this turn.

    Outer Developer resumptions left: #{left} of #{ctx.config.outer_resumptions}. When they are spent, the Build stops as `guard-violation`.

    Delete or restore exactly these paths, and nothing else:

    #{Enum.join(lines, "\n")}

    Delete each `delete:` path (untracked files and directories, with `rm -rf <path>`). Deleting the listed entries added to the Approved copy (`#{Path.join(@approved_base, ctx.slug)}`) restores the frozen package.
    Restore each `restore:` path (a modified, deleted or mode-changed tracked file) by running exactly its command, `git show HEAD:<path> > <path> && chmod <mode> <path>`, `<mode>` being the file's HEAD mode (644 or 755); the chmod also undoes a mode-only change. Do not use `git checkout` or `git restore`: they write the worktree index under control's `.git`, which the write boundary denies.
    Never run `git clean`, `git stash`, `git reset`, `git checkout` or `git restore` on the tree, and never override TMPDIR. Then end your turn; the controller checks the guard again.
    """ <> task_context(ctx, nil, "developer")
  end

  defp shell_quote(path) do
    if path =~ ~r/^[A-Za-z0-9._\/@%+=:,-]+$/,
      do: path,
      else: "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp verify_guarded_turn(ctx, session_id, number, notes, invocation) do
    with {:ok, candidate_id} <- Kogen.Git.candidate_id(ctx.root),
         :verify <- review_no_change(ctx, candidate_id, session_id, number),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "developer_session_id" => session_id,
             "developer_notes" => notes_record(notes),
             "developer_invocation" => invocation
           }),
         {:ok, ctx, jev} <- read_notes(ctx, candidate_id, notes),
         ctx = Map.put(ctx, :turn_jev, jev),
         :verify <- pre_verification(ctx, session_id, number, notes, jev) do
      verify_frozen(ctx, session_id, number, notes, invocation, candidate_id)
    else
      {:error, reason} -> stop(ctx, reason)
      {:settled, result} -> result
    end
  end

  # One immutable Candidate tree T: the complete offline gate, then every
  # selected live target and one provisional read-only Review of exactly T
  # as concurrent jobs, all settled before anything else happens. The
  # Developer stays idle throughout.
  defp verify_frozen(ctx, session_id, number, notes, invocation, candidate_id) do
    case unchanged_candidate(ctx, candidate_id) do
      :verify ->
        case settle_tree(ctx, session_id, number, candidate_id) do
          {:ok, ctx, %{"terminal_state" => "pending"} = state} ->
            resume_after_failed_cycle(ctx, session_id, number, state, notes, invocation)

          {:ok, ctx, _state} ->
            settle(ctx, session_id, number, notes, invocation, candidate_id)

          {:error, ctx, reason} ->
            stop(ctx, reason)
        end

      {:settled, result} ->
        result
    end
  end

  @doc """
  Shared settlement primitive of one frozen tree: runs the controller
  verification cycle (offline gate, then every selected live target beside
  one provisional read-only Review of exactly `candidate_id`, all settled) and
  adopts the provisional job's records. Returns the updated context and the
  settled verification state; it never launches or resumes a Developer.
  """
  @spec settle_tree(map(), String.t() | nil, non_neg_integer(), String.t()) ::
          {:ok, map(), map()} | {:error, map(), String.t()}
  def settle_tree(ctx, session_id, number, candidate_id) do
    env =
      ctx
      |> cycle_env()
      |> Map.put(:companions, &provisional_review_jobs(ctx, candidate_id, session_id, number, &1))

    case Verification.run_cycle(ctx.execution, session_id, candidate_id, env) do
      {:ok, execution, state} ->
        case take_provisional(ctx, execution, candidate_id) do
          {:ok, ctx} ->
            ctx = %{ctx | execution: execution, workspace: execution.workspace || ctx.workspace}
            # The newest base workspace is removed when the Build ends.
            Process.put(:kogen_base_workspace, ctx.workspace)
            {:ok, ctx, state}

          {:error, reason} ->
            {:error, %{ctx | execution: execution}, reason}
        end

      # The provisional job may have written records before the cycle failed.
      {:error, reason} ->
        {:error, adopt_provisional_records(ctx), reason}
    end
  end

  defp review_no_change(
         %{review_candidate_id: candidate_id} = ctx,
         candidate_id,
         session_id,
         number
       ) do
    if Map.get(ctx, :review_nochange_count, 0) == 0 do
      prompt =
        "The Candidate is unchanged after the Review finding. This same-session continuation does not spend an outer resumption. Address the finding and change the Candidate; a second unchanged result stops the Build.\n\n" <>
          Map.get(ctx, :review_reason, "") <> task_context(ctx, nil, "developer")

      ctx = Map.merge(ctx, %{review_nochange_count: 1, developer_prompt: prompt})

      {:settled,
       receive_developer(ctx, session_id, number, resume_developer(ctx, session_id, prompt))}
    else
      {:settled,
       stop(ctx, "Candidate unchanged after a second same-session Review continuation", %{
         "stop_category" => "unchanged-candidate"
       })}
    end
  end

  defp review_no_change(_ctx, _candidate_id, _session_id, _number), do: :verify

  # The existing Jev and missing-selector rules, applied before any cycle. An
  # objection is decided here only when no cycle of this attempt has failed:
  # otherwise the existing supersession rule can still apply once this turn's
  # cycle passes, so the decision waits for settlement as before.
  defp pre_verification(ctx, session_id, number, notes, jev) do
    objections = Kogen.Jev.objections(jev)

    failed_before? =
      Enum.any?(ctx.execution.state["cycles"] || [], &(&1["status"] == "failed"))

    if objections != [] and not failed_before? do
      {:settled, cannot_comply(ctx, number, notes, objections, false, nil)}
    else
      case readiness_findings(ctx) do
        [] -> :verify
        [{:unfinished, items} | _] -> {:settled, unfinished_work(ctx, session_id, number, items)}
        [{:rework, reason} | _] -> {:settled, rework(ctx, session_id, number, reason)}
      end
    end
  end

  @doc """
  Readiness of the Candidate before any cycle: required proof selectors must
  exist, and controller runtime paths cannot enter publication. Missing test
  names and changed live-owner coverage are disclosed to Review but do not
  block repair. `{:unfinished, items}` is missing required proof work;
  `{:rework, reason}` is a refusal. Shared by the automatic loop and freeze.
  """
  @spec readiness_findings(map()) :: [{:unfinished, [String.t()]} | {:rework, String.t()}]
  def readiness_findings(ctx) do
    missing = VerificationPlan.missing_selectors(ctx.plan, ctx.catalog, ctx.root)

    [
      if(missing != [], do: {:unfinished, missing}),
      case prospective_publication(ctx) do
        {:error, reason} -> {:rework, reason}
        _ -> nil
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The combined implementation plus the prospective Complete package must fit
  # forbidden runtime paths before any verification cycle. Exact staged tree
  # and lifecycle paths are checked again at publication.
  defp prospective_publication(ctx) do
    case Kogen.Git.validate_prospective_publication(
           ctx.root,
           ctx.base_commit,
           ctx.approved_entries,
           Path.join(@complete_base, ctx.slug)
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, "Publication preflight refused: " <> reason}
    end
  end

  # A Developer turn that leaves the Candidate id unchanged after a failed
  # cycle would re-run the same failure; the Build stops with the previous
  # cycle's class and signature instead. A provider failure never reaches
  # here (it stops the Build), and a changed Candidate is verified normally.
  defp unchanged_candidate(ctx, candidate_id) do
    case List.last(ctx.execution.state["cycles"] || []) do
      %{"status" => "failed", "candidate_id" => ^candidate_id} = cycle
      when not is_map_key(cycle, "class") or :erlang.map_get("class", cycle) != "provider" ->
        class = cycle["class"] || "paid"

        signature = FailureSignature.derive(cycle, ctx.execution.context, ctx.catalog, [])

        reason =
          "Candidate unchanged since failed cycle #{cycle["sequence"]} (class #{class}); " <>
            "the controller did not re-run it; signature: #{Jason.encode!(signature)}"

        {:settled,
         stop(ctx, reason, %{
           "stop_class" => "unchanged_candidate",
           "unchanged_candidate" => %{
             "cycle" => cycle["sequence"],
             "class" => class,
             "candidate_id" => candidate_id,
             "signature" => signature
           }
         })}

      _ ->
        :verify
    end
  end

  defp cycle_env(ctx) do
    %{
      root: ctx.root,
      control_root: ctx.control,
      route: ctx.config.route,
      catalog: ctx.catalog,
      plan: ctx.plan,
      scenarios: ctx.contract.scenarios,
      base_commit: ctx.base_commit,
      workspace: ctx.workspace,
      prior_receipts: prior_receipts(ctx)
    }
    |> put_dispatches_left(ctx)
  end

  defp put_dispatches_left(env, %{progress: %{} = progress}),
    do: Map.put(env, :dispatches_left, Progress.remaining(progress).dispatches)

  defp put_dispatches_left(env, _ctx), do: env

  # The attempt's verification context binds the frozen route, package and
  # catalog digest (so a restart can prove a receipt's binding) and the
  # frozen live concurrency ceiling.
  defp verification_roots(ctx) do
    %{
      control_root: ctx.control,
      candidate_root: ctx.root,
      frozen: %{"context" => frozen_context_digest(ctx)},
      max_concurrency: Map.get(ctx.config, :live_concurrency)
    }
  end

  # After an interruption or pause only the settled verification state the
  # continuation report names, byte-verified, can lend receipts; the
  # Verification rules then reuse a passed one only on the identical tree,
  # catalog and frozen context. Anything unverifiable lends nothing.
  defp prior_receipts(%{continuation: %{report: %{"budget_state" => budget}}} = ctx)
       when is_map(budget) do
    with path when is_binary(path) <- budget["state"],
         sha when is_binary(sha) <- budget["state_sha256"],
         {:ok, receipts} <- Verification.reusable_prior(Path.expand(path, ctx.control), sha) do
      receipts
    else
      _ -> []
    end
  end

  defp prior_receipts(_ctx), do: []

  defp retry_budgets(config, %{report: %{"budget_state" => budget}}) when is_map(budget) do
    %{
      verification:
        max(
          (budget["verification_retries"] || config.verification_retries) -
            (budget["failures_since_pass"] || 0),
          0
        ),
      offline:
        max(
          (budget["offline_retries"] || config.offline_retries || 0) -
            (budget["offline_failures"] || 0),
          0
        )
    }
  end

  defp retry_budgets(%{offline_retries: offline} = config, _continuation)
       when is_integer(offline),
       do: %{verification: config.verification_retries, offline: offline}

  defp retry_budgets(config, _continuation), do: config.verification_retries

  defp resume_after_failed_cycle(ctx, session_id, number, state, notes, invocation) do
    cycle = List.last(state["cycles"]) || %{}
    attempt = current_attempt(ctx)

    previous =
      List.wrap(attempt["failure_signatures"]) ++ List.wrap(attempt["cycle_signatures"])

    signature = FailureSignature.derive(cycle, ctx.execution.context, ctx.catalog, previous)
    cycle = Map.put(cycle, "signature", signature)

    # An Approved-copy change during the cycle is the controller phase's,
    # never the Developer's to clean up.
    # An Approved-copy change during the cycle is the controller phase's,
    # never the Developer's to clean up. The provisional Review of the same
    # tree joins this one handoff: its validated findings become open
    # findings, and every failure and finding counts toward progress.
    ctx = observe_cycle(ctx, cycle)

    with :ok <- approved_unchanged(ctx),
         {:ok, ctx} <-
           note_time(ctx, "repair handoff"),
         {:ok, ctx, findings} <- provisional_findings(ctx, cycle["candidate_id"], session_id),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "developer_session_id" => session_id,
             "developer_notes" => notes_record(notes),
             "developer_invocation" => invocation,
             "cycle_signatures" => List.wrap(attempt["cycle_signatures"]) ++ [signature]
           }),
         {:ok, ctx} <- record_progress(ctx, cycle, findings, false) do
      prompt = verification_failure_prompt(ctx, state, cycle, findings)

      ctx =
        Map.merge(ctx, %{
          developer_prompt: prompt,
          provider_retried: false,
          handoff_at_ms: System.os_time(:millisecond)
        })

      result = resume_developer(ctx, session_id, prompt)
      receive_developer(ctx, session_id, number, result)
    else
      {:error, reason} -> stop(ctx, reason)
      {:settled, result} -> result
    end
  end

  # Every failed receipt of the cycle with its class, retained locators and
  # digests, target evidence and primary failure lines, as absolute control
  # paths that open from the Candidate cwd, plus every provisional Review
  # finding and cancelled job, in one handoff. The controller's context,
  # state and history paths are never given out.
  defp verification_failure_prompt(ctx, state, cycle, findings) do
    %{
      cycle: cycle,
      state: state,
      context: ctx.execution.context,
      control: ctx.control,
      candidate_root: ctx.root,
      receipt_path: &Verification.receipt_path(ctx.execution, &1, &2),
      review_findings: Enum.map(findings, &handoff_finding/1)
    }
    |> FailureHandoff.render()
    |> Kernel.<>(handoff_time_line(ctx))
  end

  # A tracking finding keeps the Reviewer's words in its origin.
  defp handoff_finding(finding) do
    origin = finding["origin"] || %{}
    evidence = (finding["evidence"] || origin["evidence"]) |> List.wrap() |> List.first()

    %{
      "id" => finding["id"],
      "severity" => finding["severity"] || "blocking",
      "summary" =>
        finding["summary"] || finding["reason"] || origin["reason"] ||
          Enum.join(List.wrap(finding["scenario_ids"]), ", "),
      "path" => (is_map(evidence) && evidence["path"]) || finding["path"]
    }
  end

  # Frozen progress accounting across rounds and restarts: the unresolved
  # failure signatures and open finding ids of this round, the actual
  # provider dispatches it made, and whether it was a same-tree Review
  # no-change round. Resolving one finding never resets a spent counter.
  defp record_progress(%{progress: nil} = ctx, _cycle, _findings, _no_change), do: {:ok, ctx}

  defp record_progress(ctx, cycle, findings, no_change?) do
    # Every record_progress call issues one repair handoff, so it charges one
    # Developer resumption against the frozen ceiling on the automatic path;
    # a further handoff over the ceiling
    # stops with the named class `developer_resumption_limit`.
    round = %{
      tree: cycle["candidate_id"],
      signatures: round_signatures(ctx, cycle, findings),
      dispatches: cycle_dispatches(cycle),
      review_no_change: no_change?,
      flaky: List.wrap(cycle["flaky"]) != [],
      developer_resumption: true
    }

    case Progress.record_round(ctx.progress, round) do
      {:ok, progress} ->
        ctx = %{ctx | progress: progress}

        record_attempt(ctx, %{"progress" => Progress.to_map(progress)})

      {:stop, class, details} ->
        summary = details |> Map.delete(:state) |> Jason.encode!() |> Jason.decode!()

        {:settled,
         stop(
           %{ctx | progress: details[:state] || ctx.progress},
           stop_message(class, details),
           %{
             "stop_category" => "no-progress",
             "stop_class" => to_string(class),
             "progress" => summary
           }
         )}
    end
  end

  defp stop_message(:developer_resumption_limit, details),
    do:
      "developer resumption limit spent (class developer_resumption_limit); #{details[:next_action]}"

  defp stop_message(class, details), do: "no progress: #{class}; #{details[:next_action]}"

  # Build timing is diagnostic. Each controller span is charged at a phase
  # boundary, to the Build and to that phase, and persisted with the progress
  # state; time the controller was down is never
  # charged, because a reopened context starts a fresh span. Nothing here
  # stops, cancels or refuses anything for elapsed time.
  defp charge_elapsed(%{progress: nil} = ctx, _phase), do: {:ok, ctx}

  defp charge_elapsed(ctx, phase) do
    now = System.os_time(:millisecond)
    started = Map.get(ctx, :span_started_ms, now)
    progress = Progress.charge(ctx.progress, now - started, phase)
    ctx = ctx |> Map.put(:progress, progress) |> Map.put(:span_started_ms, now)
    warn_slow_build(ctx)
  end

  # Passing `build_time_nudge_minutes` logs one clear warning and records the
  # line for the Developer handoff; the Build continues.
  defp warn_slow_build(ctx) do
    if Progress.nudge_due?(ctx.progress) do
      line = time_nudge_line(ctx.progress)
      Logger.warning("Build #{ctx[:slug]} time nudge: " <> line)
      progress = Progress.mark_nudged(ctx.progress)
      ctx = %{ctx | progress: progress}
      record_attempt(ctx, %{"progress" => Progress.to_map(progress), "time_nudge" => line})
    else
      record_attempt(ctx, %{"progress" => Progress.to_map(ctx.progress)})
    end
  end

  defp time_nudge_line(progress) do
    summary = Progress.time_summary(progress)
    minutes = summary["nudge_minutes"]

    phases =
      summary["phases"]
      |> Enum.sort_by(fn {name, _ms} -> name end)
      |> Enum.map_join(", ", fn {name, ms} -> "#{name} #{minutes_text(ms)}" end)

    cycles = Enum.map_join(summary["cycles_ms"], ", ", &minutes_text/1)

    "Build time is diagnostic only and this Build is not stopped for it: #{minutes_text(summary["elapsed_ms"])} of active time spent, past the configured #{minutes}-minute nudge" <>
      if(phases == "", do: "", else: "; per phase: #{phases}") <>
      if(cycles == "", do: "", else: "; per verification cycle: #{cycles}") <>
      ". Report progress, narrow the scope, and finish or hand off the concrete remaining work."
  end

  defp minutes_text(ms), do: "#{Float.round(ms / 60_000, 1)} min"

  # The handoff line, present once the Build has passed its nudge.
  defp handoff_time_line(%{progress: %{} = progress}) do
    if Progress.past_nudge?(progress), do: "\n\n" <> time_nudge_line(progress) <> "\n", else: ""
  end

  defp handoff_time_line(_ctx), do: ""

  # Records the durations a repair round cost (measurement only).
  defp observe_cycle(ctx, cycle) do
    with %{progress: %{} = progress} <- ctx,
         {:ok, started, _} <- DateTime.from_iso8601(cycle["started_at"] || ""),
         {:ok, finished, _} <- DateTime.from_iso8601(cycle["finished_at"] || "") do
      cycle_ms = DateTime.diff(finished, started, :millisecond)
      %{ctx | progress: Progress.observe(progress, cycle_ms: cycle_ms)}
    else
      _ -> ctx
    end
  end

  defp observe_turn(%{handoff_at_ms: at, progress: %{} = progress} = ctx) do
    turn = System.os_time(:millisecond) - at

    ctx
    |> Map.delete(:handoff_at_ms)
    |> Map.put(:progress, Progress.observe(progress, turn_ms: turn))
  end

  defp observe_turn(ctx), do: ctx

  @doc false
  # Called at every phase boundary: charges the elapsed active span to the
  # phase and warns once past the nudge. Diagnostic only; never stops.
  @spec note_time(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def note_time(ctx, boundary), do: charge_elapsed(ctx, boundary)

  defp round_signatures(ctx, cycle, findings) do
    receipts =
      List.wrap(cycle["failures"]) ++
        Enum.reject(List.wrap(cycle["receipts"]), &(&1["status"] in ["passed", "cancelled"]))

    failed =
      receipts
      |> Enum.uniq_by(&{&1["target"], &1["log_sha256"]})
      |> Enum.map(fn receipt ->
        one = Map.merge(cycle, %{"status" => "failed", "receipts" => [receipt]})
        signature = FailureSignature.derive(one, ctx.execution.context, ctx.catalog, [])
        "#{signature["target"]}:#{signature["digest"]}"
      end)

    failed =
      if failed == [] and is_map(cycle["failure"]) do
        signature = FailureSignature.derive(cycle, ctx.execution.context, ctx.catalog, [])
        ["#{signature["target"]}:#{signature["digest"]}"]
      else
        failed
      end

    failed ++
      for %{"id" => id} <- findings, id != "provisional-review", do: "finding:#{id}"
  end

  defp cycle_dispatches(cycle) do
    case cycle["dispatch_count"] || cycle["dispatches"] do
      list when is_list(list) -> length(list)
      count when is_integer(count) -> count
      _ -> 0
    end
  end

  # No Kogen code parses `notes`: they are recorded verbatim as unverified
  # claims and only Jev reads them. Every outcome below is decided by
  # controller code from settled verification, the Candidate and Jev's
  # validated answers, so no handoff-format failure exists. Exhausted
  # verification stops the Build before Jev and Review.
  defp settle(ctx, session_id, number, notes, invocation, candidate_id) do
    with {:ok, ctx, verification} <- settle_verification(ctx, session_id, candidate_id),
         receipts = normalized_final_receipts(verification),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "candidate_id" => candidate_id,
             "developer_session_id" => session_id,
             "developer_notes" => notes_record(notes),
             "developer_invocation" => invocation,
             "receipts" => receipts
           }) do
      objections = Kogen.Jev.objections(ctx[:turn_jev] || %{})

      cond do
        verification["terminal_state"] == "passed" ->
          settle_notes(ctx, candidate_id, session_id, number, notes, verification)

        # An objection deferred past an earlier failed cycle stays the reason
        # when this attempt's verification then stops.
        objections != [] ->
          cannot_comply(ctx, number, notes, objections, true, verification)

        true ->
          stop(ctx, terminal_stop_reason(ctx, verification), terminal_details(ctx, verification))
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  # Jev read this turn's notes once, before verification; a passing cycle
  # reuses that reading rather than asking again.
  defp settle_notes(ctx, candidate_id, session_id, number, notes, verification) do
    case ctx[:turn_jev] do
      %{"candidate_id" => ^candidate_id} = jev ->
        settle_outcome(ctx, candidate_id, session_id, number, notes, verification, jev)

      _ ->
        case read_notes(ctx, candidate_id, notes) do
          {:ok, ctx, jev} ->
            settle_outcome(ctx, candidate_id, session_id, number, notes, verification, jev)

          {:error, reason} ->
            stop(ctx, reason)
        end
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
    missing = VerificationPlan.missing_selectors(ctx.plan, ctx.catalog, ctx.root)

    cond do
      exhausted? ->
        stop(ctx, terminal_stop_reason(ctx, verification), terminal_details(ctx, verification))

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
        do: reason <> "; " <> terminal_stop_reason(ctx, verification),
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

  # A provisional Review of exactly this tree already ran beside the live
  # targets: its verdict is received now, after settlement, through the same
  # validation, re-ask and provider rules as any Review. Otherwise (no
  # companion ran, or it did not produce a result for this tree) the fresh
  # Review starts now from the settled receipts.
  defp report_and_review(ctx, candidate_id, session_id, number, jev) do
    ctx = Map.merge(ctx, %{review_reasked: false, review_provider_retry_count: 0})

    case ctx.provisional do
      %{"candidate_id" => ^candidate_id, "status" => "completed", result: result} = provisional ->
        case settle_handoff(ctx, candidate_id, jev) do
          {:ok, ctx} ->
            ctx = Map.put(ctx, :review_record_bytes, provisional[:record_bytes])
            receive_review(%{ctx | provisional: nil}, candidate_id, session_id, number, result)

          {:error, reason} ->
            stop(ctx, reason)
        end

      _ ->
        cycle = List.last(ctx.execution.state["cycles"])
        unchanged = &bound_inputs_unchanged(&1, candidate_id, session_id)

        # A provisional Review that produced no result may already have
        # written this attempt's first packet; it stays verifiable as
        # superseded and the settled Review gets its own packet.
        prepared =
          case record_attempt(ctx, supersede_packet(current_attempt(ctx))) do
            {:ok, ctx} ->
              prepare_review(
                %{ctx | review_packet: nil},
                candidate_id,
                cycle,
                jev,
                "settled",
                unchanged
              )

            {:error, reason} ->
              {:error, ctx, reason}
          end

        case prepared do
          {:ok, ctx} ->
            Process.put(:kogen_base_workspace, ctx.workspace)
            result = launch_review(ctx, candidate_id, :settled)
            receive_review(ctx, candidate_id, session_id, number, result)

          {:error, ctx, reason} ->
            stop(ctx, reason)
        end
    end
  end

  # The handoff report, reference snapshots and one immutable review packet
  # for `candidate_id`, from the receipts the attempt holds now: every
  # settled receipt, or only the passed offline gate for a provisional
  # Review.
  defp prepare_review(ctx, candidate_id, cycle, jev, outcome, unchanged) do
    attempt = current_attempt(ctx)

    # Each step returns the newest ctx, so a refusal after a record write
    # still stops with the records this controller already wrote.
    steps = [
      fn ctx ->
        with {:ok, changes} <- candidate_changes(ctx.root, candidate_id),
             {:ok, ledger} <- verification_ledger(ctx, candidate_id, attempt, cycle) do
          {base_suite, workspace} = base_suite(ctx, candidate_id)
          ctx = %{ctx | workspace: workspace || ctx.workspace}

          report =
            handoff_report(ctx, candidate_id, attempt, cycle, ledger, base_suite, jev, changes)

          with {:ok, references} <- snapshot_references(report, ctx),
               {:ok, ctx} <-
                 record_attempt(ctx, %{
                   "outcome" => outcome,
                   "handoff" => report,
                   "verification_ledger" => ledger,
                   "base_suite" => base_suite,
                   "developer_reference_snapshots" => references
                 }) do
            {:ok, %{ctx | references: references}}
          end
        end
      end,
      &with(:ok <- unchanged.(&1), do: {:ok, &1}),
      &record_attempt(&1, %{
        "scenario_receipts" => scenario_receipts(&1),
        "reference_snapshots" => &1.references
      }),
      &write_review_packet(&1, candidate_id, packet_cycle(outcome, cycle)),
      &with(:ok <- unchanged.(&1), do: {:ok, &1})
    ]

    Enum.reduce_while(steps, {:ok, ctx}, fn step, {:ok, ctx} ->
      case step.(ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, reason} -> {:halt, {:error, ctx, reason}}
      end
    end)
  end

  # After settlement the report is rebuilt from every settled receipt as
  # `settled_handoff`; `handoff` stays the report the provisional packet
  # carries, and the addendum packet binds the settled receipts.
  defp settle_handoff(ctx, candidate_id, jev) do
    attempt = current_attempt(ctx)
    cycle = List.last(ctx.execution.state["cycles"])

    with {:ok, changes} <- candidate_changes(ctx.root, candidate_id),
         report =
           handoff_report(
             ctx,
             candidate_id,
             attempt,
             cycle,
             attempt["verification_ledger"],
             attempt["base_suite"],
             jev,
             changes
           ),
         {:ok, references} <- snapshot_references(report, ctx),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "outcome" => "settled",
             "settled_handoff" => report,
             "developer_reference_snapshots" =>
               Map.merge(attempt["developer_reference_snapshots"] || %{}, references),
             "scenario_receipts" => scenario_receipts(ctx)
           }) do
      {:ok, %{ctx | references: Map.merge(ctx.references, references)}}
    end
  end

  defp packet_cycle("provisional", cycle), do: {:cycle, cycle["sequence"]}
  defp packet_cycle(_outcome, cycle), do: {:settled, cycle["sequence"]}

  defp handoff_report(ctx, candidate_id, attempt, cycle, ledger, base_suite, jev, changes) do
    Report.build(%{
      contract: ctx.contract,
      attempt_token: ctx.token,
      candidate_id: candidate_id,
      open_findings: Tracking.open_findings(ctx.tracking),
      changes: changes,
      receipts: attempt["receipts"],
      proofs: List.wrap(cycle["proofs"]),
      labels: Map.new(ctx.plan.scenarios, &{&1["id"], &1["label"]}),
      ledger: ledger,
      base_suite: base_suite,
      jev: jev,
      existing?: &File.regular?(Path.join(ctx.root, &1))
    })
  end

  defp launch_review(ctx, candidate_id, mode) do
    prompt =
      render_reviewer_prompt(ctx.intent, candidate_id, ctx.config, ctx.control) <>
        provisional_section(ctx, mode) <>
        reviewer_notes_section(ctx) <> task_context(ctx, candidate_id, "reviewer")

    Kogen.Harness.launch_reviewer(
      prompt,
      ctx.config.reviewer.model,
      ctx.config.reviewer.effort,
      reviewer_launch_context(ctx)
    )
  end

  # The verdict schema is chosen per launch (`per-launch-verdict-schema`):
  # `ledger` is required exactly when this attempt's packet carries a
  # nonempty ledger. `Kogen.Harness.with_scenarios/2` additionally
  # constrains `scenarios` to exactly the Approved Intent's scenario ids
  # (enum, minItems=maxItems=n) and requires the per-launch evidence
  # `receipt` field.
  defp reviewer_launch_context(ctx) do
    ctx
    |> scrubbed_context(:reviewer)
    |> Kogen.Harness.with_ledger(ledger_paths(ctx))
    |> maybe_with_scenarios(ctx)
  end

  defp provisional_section(_ctx, :settled), do: ""

  defp provisional_section(ctx, :provisional) do
    live =
      ctx.targets
      |> Enum.filter(&(get_in(ctx.catalog, [:targets, &1, "provider_backed"]) == true))
      |> Enum.join(", ")

    """

    ## Provisional Review

    The complete offline gate passed on this exact Candidate tree. Provider-backed
    targets (#{if live == "", do: "none", else: live}) are running concurrently and their
    receipts are not in this packet. Judge the change, its tests and whether each test
    oracle actually establishes its scenario now; a passing test does not settle a weak
    oracle. This verdict is provisional: it never authorizes publication. After every
    job settles you will be resumed once with the settled receipts for an evidence
    addendum, and only an accepting addendum verdict on this same tree can join
    acceptance.
    """
  end

  # The provisional Reviewer of tree T is one fan-out companion, started only
  # after the offline gate and every applicable prepare passed. It runs in its
  # own process while live targets run and never touches the Developer. It
  # returns the harness result and the controller records it wrote; the
  # controller joins them only after every job settled.

  # Called in the controller process once the offline gate passed.
  defp provisional_review_jobs(ctx, candidate_id, session_id, number, offline_cycle) do
    ctx = Map.put(ctx, :record_sink, {self(), ctx.token})

    [
      %{
        id: "provisional-review",
        run: fn job ->
          # The Reviewer's process group is registered with the fan-out job, so
          # a cancellation reaps it by identity at once, like a live target.
          ctx = %{ctx | runtime: Map.put(ctx.runtime, :on_start, job.on_start)}
          provisional_review(ctx, candidate_id, session_id, number, offline_cycle)
        end
      }
    ]
  end

  # After settlement the controller adopts the newest records the
  # provisional job wrote (reported as it wrote them) and keeps its harness
  # result for the join. A cancelled, crashed or unstarted job is recorded
  # with its status, never guessed.
  defp take_provisional(ctx, execution, candidate_id) do
    # The newest record the job wrote, whatever it returned.
    latest = last_provisional_record(ctx.token, nil)
    ctx = if latest, do: Map.merge(ctx, latest), else: ctx
    adopt_latest = fn ctx -> if latest, do: %{ctx | tracking: latest.tracking}, else: ctx end

    companions = companions(execution)
    # The companion function itself failing is recorded under "companions".
    entry = companions["provisional-review"] || companions["companions"]

    case entry do
      nil ->
        {:ok, %{ctx | provisional: nil}}

      %{"status" => "settled", "result" => %{term: {patch, result}} = outcome}
      when is_map(patch) ->
        ctx = ctx |> Map.merge(patch) |> adopt_latest.()
        Process.put(:kogen_base_workspace, ctx.workspace)
        status = if result, do: outcome["status"], else: "error"

        provisional =
          outcome
          |> Map.drop([:term])
          |> Map.merge(%{"candidate_id" => candidate_id, "status" => status})
          |> Map.put(:result, result)

        record_provisional(%{ctx | provisional: provisional})

      entry ->
        result = if is_map(entry["result"]), do: Map.drop(entry["result"], [:term]), else: %{}

        provisional = %{
          "candidate_id" => candidate_id,
          "status" =>
            if(entry["status"] == "settled", do: result["status"], else: entry["status"]),
          "reason" => result["reason"] || entry["reason"],
          result: nil
        }

        Process.put(:kogen_base_workspace, ctx.workspace)
        record_provisional(%{ctx | provisional: provisional})
    end
  end

  defp adopt_provisional_records(ctx) do
    case last_provisional_record(ctx.token, nil) do
      nil -> ctx
      latest -> %{ctx | tracking: latest.tracking}
    end
  end

  defp last_provisional_record(ref, latest) do
    receive do
      {:kogen_provisional_record, ^ref, patch} -> last_provisional_record(ref, patch)
    after
      0 -> latest
    end
  end

  defp provisional_review(ctx, candidate_id, session_id, _number, offline_cycle) do
    receipts = List.wrap(offline_cycle["receipts"])
    unchanged = &provisional_inputs_unchanged(&1, candidate_id)

    with {:ok, ctx} <-
           record_attempt(
             ctx,
             Map.merge(supersede_packet(current_attempt(ctx)), %{
               "candidate_id" => candidate_id,
               "developer_session_id" => session_id,
               "receipts" => receipts
             })
           ),
         ctx = %{ctx | review_packet: nil},
         {:ok, ctx} <-
           prepare_review(
             ctx,
             candidate_id,
             offline_cycle,
             ctx[:turn_jev],
             "provisional",
             unchanged
           ) do
      review_record_bytes = ctx.tracking.bytes
      result = launch_review(ctx, candidate_id, :provisional)

      %{
        "status" => "completed",
        "candidate_id" => candidate_id,
        "reviewer_session_id" => review_session(result),
        "verdict" => review_verdict(result),
        :record_bytes => review_record_bytes,
        :term => {provisional_patch(ctx), result}
      }
    else
      {:error, ctx, reason} ->
        %{
          "status" => "error",
          "reason" => to_string(reason),
          :term => {provisional_patch(ctx), nil}
        }

      {:error, reason} ->
        %{"status" => "error", "reason" => to_string(reason), :term => nil}
    end
  rescue
    error -> %{"status" => "error", "reason" => Exception.message(error), :term => nil}
  end

  # A repaired tree in the same attempt gets its own packet; the earlier
  # binding stays verifiable as superseded.
  defp supersede_packet(%{"review_packet" => %{} = binding} = attempt),
    do: %{
      "review_packet" => nil,
      "superseded_review_packets" => List.wrap(attempt["superseded_review_packets"]) ++ [binding]
    }

  defp supersede_packet(_attempt), do: %{}

  # The live jobs are still writing their own verification files, so the
  # provisional check covers everything except the in-progress cycle.
  defp provisional_inputs_unchanged(ctx, candidate_id) do
    with :ok <- inputs_unchanged(ctx),
         {:ok, actual} <- Kogen.Git.candidate_id(ctx.root) do
      if actual == candidate_id,
        do: :ok,
        else:
          {:error, "Candidate mutated during provisional Review (#{candidate_id} -> #{actual})"}
    end
  end

  defp provisional_patch(ctx),
    do: Map.take(ctx, [:tracking, :references, :review_packet, :workspace])

  defp review_session({:ok, %{session_id: id}}), do: id
  defp review_session(_result), do: nil

  defp review_verdict({:ok, %{response: %{"verdict" => verdict}}}), do: verdict
  defp review_verdict(_result), do: nil

  # After settlement the controller adopts the records the provisional job
  # wrote (its tracking state is the newest) and keeps its harness result
  # for the join. Any other companion outcome is recorded, never guessed.

  defp record_provisional(ctx) do
    summary =
      ctx.provisional
      |> Map.drop([:result])
      |> Map.take(~w(status candidate_id reviewer_session_id verdict reason))

    case record_attempt(ctx, %{"provisional_review" => summary}) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, reason}
    end
  end

  defp companions(%{companions: companions}) when is_map(companions), do: companions
  defp companions(_execution), do: %{}

  # Findings of a provisional Review of this tree, validated like any verdict
  # and applied as open findings, so one handoff carries every failure and
  # finding. An unusable provisional result is named, never guessed.
  defp provisional_findings(ctx, candidate_id, session_id) do
    case ctx.provisional do
      # An accepting verdict on a tree that failed verification decides
      # nothing; the repaired tree is reviewed again.
      %{"candidate_id" => ^candidate_id, "status" => "completed", "verdict" => verdict}
      when is_binary(verdict) and verdict != "rework" ->
        {:ok, %{ctx | provisional: nil}, Tracking.open_findings(ctx.tracking)}

      %{"candidate_id" => ^candidate_id, "status" => "completed", result: {:ok, verdict}} ->
        binding = %{
          candidate_id: candidate_id,
          attempt_token: ctx.token,
          root: ctx.root,
          control: ctx.control,
          tracking_path: ctx.tracking.path
        }

        with :ok <- fresh_reviewer(ctx, verdict.session_id, session_id),
             {:ok, response} <-
               Contract.verdict(
                 verdict.response,
                 ctx.contract,
                 binding,
                 Tracking.open_findings(ctx.tracking),
                 ledger_paths(ctx)
               ),
             response =
               Review.apply_ledger(
                 response,
                 current_attempt(ctx)["verification_ledger"],
                 ctx.contract
               ),
             {:ok, references} <- snapshot_references(response, ctx),
             {:ok, tracking} <-
               Tracking.apply_verdict(ctx.tracking, response, verdict.session_id, references) do
          ctx = %{
            ctx
            | tracking: tracking,
              reviewers: ctx.reviewers ++ [verdict.session_id],
              references: Map.merge(ctx.references, references),
              provisional: nil
          }

          {:ok, ctx, Tracking.open_findings(ctx.tracking)}
        else
          {:error, reason} ->
            {:ok, %{ctx | provisional: nil},
             [unavailable_finding("provisional Review verdict unusable: #{reason}")]}
        end

      %{"candidate_id" => ^candidate_id} = provisional ->
        reason =
          provisional["reason"] ||
            case provisional[:result] do
              {:error, error} -> reviewer_provider_text(error)
              _ -> provisional["status"] || "no verdict"
            end

        {:ok, %{ctx | provisional: nil},
         [unavailable_finding("provisional Review did not complete: #{reason}")] ++
           Tracking.open_findings(ctx.tracking)}

      _ ->
        {:ok, ctx, Tracking.open_findings(ctx.tracking)}
    end
  end

  defp unavailable_finding(reason),
    do: %{"id" => "provisional-review", "severity" => "info", "summary" => reason}

  # The verification-surface ledger exists only when the admission catalog
  # declares the integrity fields. It goes to the handoff report and the
  # review packet, never to Jev.
  defp verification_ledger(%{catalog: %{integrity: nil}}, _candidate_id, _attempt, _cycle),
    do: {:ok, nil}

  defp verification_ledger(ctx, candidate_id, attempt, cycle) do
    preservation =
      for proof <- List.wrap(cycle["proofs"]),
          proof["kind"] == "base_preservation",
          path <- List.wrap(proof["changed_selectors"]),
          do: path

    # Tree ids resolve in either checkout (the object store is shared); ledger
    # diff locators are relative to control, which holds the attempt directory.
    Ledger.compute(%{
      root: ctx.control,
      base_commit: ctx.base_commit,
      candidate_id: candidate_id,
      integrity: ctx.catalog.integrity,
      admission_sha256: ctx.catalog.sha256,
      candidate_sha256: cycle["catalog_sha256"],
      receipts: attempt["receipts"],
      directory: ctx.execution.directory,
      preservation: Enum.uniq(preservation)
    })
  end

  defp base_suite(%{catalog: %{integrity: nil}}, _candidate_id), do: {nil, nil}

  defp base_suite(ctx, candidate_id) do
    Ledger.base_suite(%{
      root: ctx.control,
      base_commit: ctx.base_commit,
      candidate_id: candidate_id,
      integrity: ctx.catalog.integrity,
      workspace: ctx.workspace,
      directory: ctx.execution.directory
    })
  end

  # Paths that differ between the settled Candidate tree and HEAD.
  defp candidate_changes(root, candidate_id) do
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
           cd: root,
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

  # A failed provider turn is not a verification cycle; the Build stops with
  # the harness failure (a guarded-path violation still takes precedence).
  # A turn whose output carries an explicit provider marker is labelled
  # `provider` and spends nothing: overload, capacity and 5xx resume the same
  # Developer session once with the same prompt; a usage limit, a second
  # provider failure, or a failure without a session stops as `provider`.
  defp settle_transport_failure(ctx, number, reason, evidence) do
    session_id = evidence[:session_id]
    provider_output = provider_text(evidence)
    login = ProviderMarker.login_failure(provider_output)
    marker = ProviderMarker.classify(provider_output)

    retry? =
      is_binary(session_id) and
        Map.get(ctx, :capacity_retry_count, 0) < length(@capacity_backoff_minutes)

    # The guard runs before any retry; a retry resends `developer_prompt`
    # (a guard-rework prompt included) and is not a guard rework.
    {guard, ctx} = post_developer_inputs_unchanged(ctx)

    case {guard, login, marker} do
      {:ok, %{"harness" => harness} = login, _} ->
        command = Kogen.Harness.login_command(login_binding(ctx, harness))

        stop(
          ctx,
          "developer: #{harness} login rejected (401) (class environment); run `#{command}`",
          %{
            "stop_class" => "environment",
            "provider" => login,
            "next_command" => command,
            "developer_session_id" => session_id,
            "developer_invocation" => invocation_evidence(evidence),
            "outer_attempt" => number,
            "stop_category" => "environment"
          }
        )

      {:ok, nil, %{"retry" => true}} when retry? ->
        retry_developer(ctx, number, session_id, marker, evidence)

      {:ok, nil, %{} = marker} ->
        stop(
          ctx,
          "provider failure during Developer turn (class provider, #{marker["kind"]}): #{marker["marker"]} #{role_label(ctx, :developer)}",
          %{
            "stop_class" => "provider",
            "provider" => marker,
            "developer_session_id" => session_id,
            "developer_invocation" => invocation_evidence(evidence),
            "outer_attempt" => number
          }
        )

      {:ok, nil, nil} ->
        case incomplete_turn_kind(reason) do
          kind when is_binary(kind) and is_binary(session_id) ->
            continue_incomplete_turn(ctx, number, session_id, kind, evidence)

          _complete_or_unknown ->
            stop(
              ctx,
              "harness failure during Developer turn: #{inspect(reason)} #{role_label(ctx, :developer)}",
              %{
                "developer_session_id" => session_id,
                "developer_invocation" => invocation_evidence(evidence),
                "outer_attempt" => number
              }
            )
        end

      {violation, _login, _marker} ->
        stop(ctx, failed_turn_violation(violation), %{
          "developer_invocation" => invocation_evidence(evidence),
          "stop_category" => "integrity"
        })
    end
  end

  # A Developer turn that reached its time box was interrupted with TERM (the
  # session persists incrementally, so it stays resumable). Elapsed time never
  # stops a Build: the same session is resumed with a nudge prompt, and the
  # nudge repeats every `developer_turn_minutes`. A nudge is not a repair
  # handoff, so it is never charged as a Developer resumption. The
  # harness holds a turn's time-box until its session id is observed.
  defp settle_turn_timeout(ctx, number, session_id, evidence) do
    count = Map.get(ctx, :turn_nudge_count, 0) + 1
    minutes = Map.get(ctx.config, :developer_turn_minutes) || @default_developer_turn_minutes
    ran = count * minutes

    entry = %{
      "session_id" => session_id,
      "nudge" => count,
      "turn_minutes" => ran,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    progress = ctx.progress && Progress.record_turn_nudge(ctx.progress, entry)

    attempt = %{
      "turn_nudges" => List.wrap(current_attempt(ctx)["turn_nudges"]) ++ [entry],
      "developer_session_id" => session_id,
      "developer_invocation" => invocation_evidence(evidence)
    }

    attempt =
      if progress, do: Map.put(attempt, "progress", Progress.to_map(progress)), else: attempt

    ctx = if progress, do: %{ctx | progress: progress}, else: ctx

    Logger.warning(
      "Developer turn #{number} has run #{ran} minutes; nudge #{count} sent (not a stop)"
    )

    case record_attempt(ctx, attempt) do
      {:ok, ctx} when is_binary(session_id) ->
        prompt = turn_nudge_prompt(ran, count)
        # The nudge is now the prompt a provider-capacity retry must resend,
        # never the stale full Developer prompt.
        ctx = Map.merge(ctx, %{turn_nudge_count: count, developer_prompt: prompt})
        receive_developer(ctx, session_id, number, resume_developer(ctx, session_id, prompt))

      {:ok, ctx} ->
        # The harness holds a turn's time-box until its session identity is
        # observed, so this is unreachable in practice; never a time-based
        # stop: the record is kept and the failure is a plain harness one.
        stop(
          ctx,
          "harness failure during Developer turn: no session identity was observed " <>
            "#{role_label(ctx, :developer)}; the Candidate is kept",
          %{
            "developer_invocation" => invocation_evidence(evidence),
            "outer_attempt" => number
          }
        )

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  @doc false
  @spec turn_nudge_prompt(pos_integer(), pos_integer()) :: String.t()
  def turn_nudge_prompt(ran, count) do
    "Your turn has run #{ran} minutes (nudge #{count}); your session and the Candidate are " <>
      "intact and you may keep working. Report your progress so far, narrow the scope to what " <>
      "the declared proof selectors and the check require, and finish, or hand off the concrete " <>
      "remaining work in your final Developer notes. This nudge is not a stop."
  end

  defp retry_developer(ctx, number, session_id, marker, evidence) do
    count = Map.get(ctx, :capacity_retry_count, 0)
    minutes = Enum.at(@capacity_backoff_minutes, count)

    case record_attempt(ctx, %{
           "provider_retries" =>
             List.wrap(current_attempt(ctx)["provider_retries"]) ++
               [
                 %{
                   "role" => "developer",
                   "session_id" => session_id,
                   "marker" => marker,
                   "backoff_minutes" => minutes
                 }
               ],
           "developer_invocation" => invocation_evidence(evidence)
         }) do
      {:ok, ctx} ->
        capacity_pause(minutes)

        ctx =
          Map.merge(ctx, %{
            provider_retried: true,
            provider_retry_count: count + 1,
            capacity_retry_count: count + 1
          })

        prompt = ctx[:developer_prompt] || developer_prompt(ctx, nil)
        receive_developer(ctx, session_id, number, resume_developer(ctx, session_id, prompt))

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  # A truncated stream, an output- or turn-limited result, or a turn that
  # never reached its terminal completion event is incomplete work, never a
  # completed handoff. Its progress text is not notes.
  defp incomplete_turn_kind({:incomplete_turn, kind, _tail}) when is_binary(kind), do: kind
  defp incomplete_turn_kind({:no_result_event, 0, _tail}), do: "no-completion"
  defp incomplete_turn_kind(_reason), do: nil

  # One bounded same-session continuation per incomplete turn, spending no
  # outer resumption; a second consecutive incomplete turn is non-progress
  # and stops with an actionable next step, the Candidate preserved.
  defp continue_incomplete_turn(ctx, number, session_id, kind, evidence) do
    count = Map.get(ctx, :incomplete_turn_count, 0)

    entry = %{"session_id" => session_id, "kind" => kind, "continuation" => count + 1}

    case record_attempt(ctx, %{
           "incomplete_turns" => List.wrap(current_attempt(ctx)["incomplete_turns"]) ++ [entry],
           "developer_session_id" => session_id,
           "developer_invocation" => invocation_evidence(evidence)
         }) do
      {:ok, ctx} when count >= @incomplete_continuations ->
        stop(
          ctx,
          "harness failure during Developer turn: it ended incomplete (#{kind}) " <>
            "#{count + 1} times in a row in session " <>
            "#{session_id}; the Candidate is preserved. Next action: inspect the retained " <>
            "Developer stream, then rerun `mix kogen.build #{ctx.slug}` to continue",
          %{
            "incomplete_turn" => %{"kind" => kind, "consecutive" => count + 1},
            "developer_session_id" => session_id,
            "outer_attempt" => number
          }
        )

      {:ok, ctx} ->
        ctx = Map.put(ctx, :incomplete_turn_count, count + 1)
        prompt = incomplete_turn_prompt(kind)
        receive_developer(ctx, session_id, number, resume_developer(ctx, session_id, prompt))

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  defp incomplete_turn_prompt(kind) do
    "Your previous turn ended incomplete (#{kind}): Kogen did not receive a completed " <>
      "response, so it is not a handoff. Continue the remaining actionable work from the " <>
      "current Candidate without repeating completed exploration, wait for any helpers you " <>
      "started, then end with your final Developer notes. If a genuine blocker prevents " <>
      "progress, say so plainly in those notes. This continuation spends no outer resumption; " <>
      "a second incomplete turn stops the Build."
  end

  defp capacity_pause(minutes) do
    # Fake harnesses exercise the state machine without imposing real provider
    # waiting time. Every managed provider session uses the full delay.
    unless System.get_env("KOGEN_HARNESS"), do: Process.sleep(minutes * 60_000)
  end

  # The tail of a failed provider stream, wherever the adapter kept it.
  defp provider_text(evidence) do
    [:output_tail, :stderr_tail, :output, :reason]
    |> Enum.map(&Map.get(evidence, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  # The catalog is no longer byte-frozen: each cycle checks the Candidate's
  # catalog as data and a violation returns to the same Developer.
  #
  # Returns `{result, ctx}`: `result` is `:ok`, `{:rework, paths}` for
  # entries added to the frozen Approved copy, or `{:stop, category,
  # message}`. Ordinary extra edits are disclosed, not refused. `ctx` carries
  # the refreshed snapshot and control Git environment events.
  defp post_developer_inputs_unchanged(ctx) do
    case rebind_candidate_references(ctx) do
      {:ok, ctx} -> guard_developer_inputs(ctx)
      {:error, ctx, reason} -> {{:stop, stop_category(reason), reason}, ctx}
    end
  end

  defp guard_developer_inputs(ctx) do
    case handoff_inputs_unchanged(ctx) do
      {:ok, added} ->
        {result, snapshot, events} =
          GuardedPaths.assess(
            ctx.guarded_snapshot,
            ctx.intent.may_change_guarded_paths,
            ctx.intent.gate_change_paths
          )

        ctx = %{ctx | guarded_snapshot: snapshot}

        case record_environment_events(ctx, events) do
          {:ok, ctx} -> record_repair_disclosures(ctx, snapshot, result, added)
          {:error, reason} -> {{:stop, "integrity", reason}, ctx}
        end

      {:error, reason} ->
        {{:stop, stop_category(reason), reason}, ctx}
    end
  end

  defp record_repair_disclosures(ctx, snapshot, {:ok, %{extra_paths: paths}}, added) do
    with {:ok, disclosure} <- GuardedPaths.repair_disclosures(snapshot, paths),
         {:ok, ctx} <- record_attempt(ctx, %{"repair_disclosures" => disclosure}) do
      {guard_result(:ok, added), ctx}
    else
      {:error, reason} -> {{:stop, "integrity", reason}, ctx}
    end
  end

  defp record_repair_disclosures(ctx, _snapshot, {:stop, _, _} = stop, added),
    do: {guard_result(stop, added), ctx}

  defp guard_result({:stop, _category, _message} = stop, _added), do: stop
  defp guard_result(:ok, []), do: :ok
  defp guard_result(:ok, added), do: {:rework, added}

  defp record_environment_events(ctx, []), do: {:ok, ctx}

  defp record_environment_events(ctx, events) do
    recorded =
      Enum.map(events, &%{"file" => &1.file, "before" => &1.before, "after" => &1.after})

    record_attempt(ctx, %{
      "environment_events" => List.wrap(current_attempt(ctx)["environment_events"]) ++ recorded
    })
  end

  # A failed turn never resumes over a violation: any finding, reworkable or
  # terminal, stops with the guard's own message as `integrity`.
  defp failed_turn_violation({:rework, paths}) do
    if Enum.any?(paths, &String.starts_with?(&1, @approved_base <> "/")),
      do: @approved_changed,
      else: GuardedPaths.violation_message(paths)
  end

  defp failed_turn_violation({:stop, _category, message}), do: message

  defp settle_verification(ctx, session_id, candidate_id) do
    case Verification.settle(ctx.execution, session_id, candidate_id) do
      {:ok, execution, verification} ->
        ctx = %{ctx | execution: execution}

        previous =
          ctx.tracking.record["attempts"]
          |> Enum.flat_map(&Map.get(&1, "failure_signatures", []))

        signatures =
          verification["cycles"]
          |> Enum.reject(&(&1["status"] == "passed"))
          |> Enum.map_reduce(previous, fn cycle, seen ->
            signature = FailureSignature.derive(cycle, execution.context, ctx.catalog, seen)
            {signature, seen ++ [signature]}
          end)
          |> elem(0)

        with {:ok, retained_state} <-
               Tracking.retain_artifact(
                 ctx.tracking,
                 "verification_state",
                 "state.json",
                 execution.state_bytes
               ),
             {:ok, ctx} <-
               record_attempt(ctx, %{
                 "verification" => verification,
                 "failure_signatures" => signatures,
                 "verification_state" => retained_state
               }) do
          {:ok, ctx, verification}
        end

      {:error, reason} ->
        {:error, "verification settlement integrity failure: #{reason}"}
    end
  end

  # The stop reason of a settled, non-passing attempt names its failure class:
  # paid exhaustion keeps today's prefix; offline exhaustion names
  # offline_retries; an environment or provider stop names its cause.
  defp terminal_stop_reason(ctx, verification) do
    cycle = List.last(verification["cycles"])
    failure = cycle["failure"] || %{}

    target =
      failure["target"] || (List.last(cycle["receipts"]) || %{})["target"] || "unknown"

    signature =
      ctx.tracking.record["attempts"]
      |> List.last()
      |> Map.get("failure_signatures", [])
      |> List.last()

    at = "cycle #{cycle["sequence"]} failed at #{failure_place(failure, target)}"

    provider = failure["provider"] || %{}

    if provider["kind"] == "login_rejected" do
      harness = provider["harness"] || "claude"
      command = Kogen.Harness.login_command(login_binding(ctx, harness))

      "make #{target}: #{harness} login rejected (401) (class environment); run `#{command}`; no retry was spent"
    else
      stop_reason(
        verification["terminal_state"],
        at,
        failure,
        "signature: #{Jason.encode!(signature)}",
        ctx.execution.context
      )
    end
  end

  defp stop_reason("offline_exhausted", at, _failure, signature, context),
    do:
      "offline retries exhausted (offline_retries: #{context["offline_retries"]}) after #{at} (class offline); #{signature}"

  defp stop_reason("environment", at, failure, _signature, _context),
    do:
      "environment failure before any provider-backed target: #{at} (class environment): #{failure["reason"] || "prepare reported an environment result"}; no retry was spent"

  defp stop_reason("provider", at, failure, _signature, _context) do
    marker = failure["provider"] || %{}

    "provider failure: #{at} (class provider, #{marker["kind"]}): #{marker["marker"]}; no retry was spent"
  end

  defp stop_reason(_paid, at, _failure, signature, _context),
    do: "verification retries exhausted after #{at} (class paid); #{signature}"

  defp failure_place(%{"kind" => "prepare"}, target), do: "the prepare step of #{target}"
  defp failure_place(_failure, target), do: "make #{target}"

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp terminal_details(ctx, verification) do
    class =
      case verification["terminal_state"] do
        "offline_exhausted" -> "offline"
        "environment" -> "environment"
        "provider" -> "provider"
        _ -> "paid"
      end

    cycle = List.last(verification["cycles"]) || %{}
    failure = cycle["failure"] || %{}
    provider = failure["provider"] || %{}

    if provider["kind"] == "login_rejected" do
      harness = provider["harness"] || "claude"
      command = Kogen.Harness.login_command(login_binding(ctx, harness))

      %{
        "stop_class" => "environment",
        "stop_category" => "environment",
        "next_command" => command
      }
    else
      %{"stop_class" => class}
    end
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

  defp ledger_paths(ctx), do: Ledger.paths(current_attempt(ctx)["verification_ledger"])

  defp scenario_ids(ctx), do: Enum.map(ctx.contract.scenarios, & &1["id"])

  # `per-launch-verdict-schema`: every Review launch gets the schema built
  # for it, constrained to exactly this Approved Intent's scenario ids. The
  # schema is never static.
  defp maybe_with_scenarios(context, ctx),
    do: Kogen.Harness.with_scenarios(context, scenario_ids(ctx))

  # One immutable packet per Review launch, written before launch; a later
  # provisional Review in the same attempt (a repaired tree) writes its own
  # per-cycle packet and the earlier binding is kept as superseded. Every
  # binding lives in controller state and the attempt, and every later input
  # check verifies it, so a rebuilt or edited packet stops the Build.
  defp write_review_packet(ctx, candidate_id, cycle) do
    input = %{
      record: ctx.tracking.record,
      record_path: Tracking.relative_path(ctx.tracking),
      record_bytes: ctx.tracking.bytes,
      candidate_id: candidate_id,
      open_findings: Enum.map(Tracking.open_findings(ctx.tracking), & &1["id"]),
      verification_disclosures: verification_disclosures(ctx)
    }

    index = length(ctx.tracking.record["attempts"]) - 1

    with {:ok, bytes} <- ReviewPacket.build(input),
         {:ok, binding} <-
           ReviewPacket.write_unique(
             ctx.tracking.path,
             index,
             packet_label(cycle),
             bytes,
             ctx.token,
             candidate_id,
             ctx.control
           ),
         {:ok, ctx} <- record_attempt(ctx, %{"review_packet" => binding}) do
      {:ok, %{ctx | review_packet: binding}}
    end
  end

  # Names come from the packet directory itself (`ReviewPacket.write_unique/7`),
  # so a packet left by a provisional Review that crashed before recording its
  # binding is never overwritten or reused: this launch is written beside it.
  defp packet_label({:cycle, sequence}), do: "cycle-#{sequence}"
  defp packet_label({:settled, sequence}), do: "settled-#{sequence}"

  defp review_packets_unchanged(ctx) do
    attempts = ctx.tracking.record["attempts"]
    current = List.last(attempts)["review_packet"]

    if ctx.review_packet != nil and ctx.review_packet != current do
      {:error, "review packet binding changed after it was written"}
    else
      Enum.reduce_while(attempts, :ok, &review_packet_unchanged(&1, &2, ctx.control))
    end
  end

  defp review_packet_unchanged(attempt, :ok, control) do
    case review_packet_unchanged(attempt, control) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  # Packet locators are relative to control, where the packets live.
  # The evidence-addendum packet of an attempt is held to the same binding.
  defp review_packet_unchanged(attempt, control) do
    current =
      case attempt["review_packet"] do
        nil -> :ok
        binding -> packet_bound(binding, attempt, control)
      end

    addendum =
      case attempt["addendum_packet"] do
        nil -> :ok
        binding -> packet_bound(binding, attempt, control)
      end

    # A superseded packet reviewed an earlier tree of this attempt: it stays
    # bound to the attempt and to its exact bytes.
    superseded =
      attempt
      |> Map.get("superseded_review_packets", [])
      |> List.wrap()
      |> Enum.find_value(:ok, fn binding ->
        result =
          if binding["attempt_token"] == attempt["attempt_token"],
            do: ReviewPacket.verify(binding, control),
            else: {:error, "superseded review packet is not bound to its attempt"}

        if result == :ok, do: nil, else: result
      end)

    Enum.find([current, addendum, superseded], :ok, &(&1 != :ok))
  end

  defp packet_bound(binding, attempt, control) do
    if binding["attempt_token"] == attempt["attempt_token"] and
         binding["candidate_id"] == attempt["candidate_id"],
       do: ReviewPacket.verify(binding, control),
       else: {:error, "review packet is not bound to its attempt and Candidate"}
  end

  defp receive_review(ctx, candidate_id, session_id, number, {:ok, verdict}) do
    binding = %{
      candidate_id: candidate_id,
      attempt_token: ctx.token,
      root: ctx.root,
      control: ctx.control,
      tracking_path: ctx.tracking.path
    }

    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         :ok <- fresh_reviewer(ctx, verdict.session_id, session_id) do
      case Contract.verdict(
             verdict.response,
             ctx.contract,
             binding,
             Tracking.open_findings(ctx.tracking),
             ledger_paths(ctx)
           ) do
        {:ok, response} ->
          accept_verdict(ctx, candidate_id, session_id, number, verdict, response)

        {:error, reason} ->
          invalid_verdict(ctx, candidate_id, session_id, number, verdict, reason)
      end
    else
      {:error, reason} ->
        stop(ctx, "Reviewer failure: #{reason} #{role_label(ctx, :reviewer)}", %{
          "invalid_verdict" => verdict.response
        })
    end
  end

  # `reviewer-reask-once`: an invalid verdict with a known session id gets
  # exactly one resume per Review launch, asking only for a corrected verdict
  # in valid shape, never a new judgement. A valid repair that keeps its
  # `verdict` value settles as usual; a second invalid verdict, or a changed
  # `verdict` value, stops the Build as today, keeping both invalid payloads.
  defp receive_review(
         ctx,
         candidate_id,
         session_id,
         number,
         {:error, {:malformed_verdict, _code, details}} = error
       )
       when is_map(details) do
    ctx = Map.put(ctx, :review_reasked, true)

    case reask_malformed_verdict(ctx, details) do
      {:ok, verdict} ->
        receive_review(ctx, candidate_id, session_id, number, {:ok, verdict})

      {:error, reask_details} ->
        stop(
          ctx,
          "Reviewer failure: #{inspect(error)}, unrepaired on re-ask #{role_label(ctx, :reviewer)}",
          %{"invalid_verdict" => details, "invalid_verdict_reask" => reask_details}
        )
    end
  end

  # `environment-and-provider-classes` point 2: a Review launch failure whose
  # evidence carries a recognised provider marker is labelled `provider` and
  # spends nothing. A retryable marker (overload, capacity, 5xx) gets one
  # fresh Review with the same packet: the packet is never rewritten
  # (`write_review_packet` already ran in `review/4`), so this rebuilds the
  # same prompt and launches a new Reviewer session. A usage limit, or a
  # second provider failure, stops the Build as `provider`.
  defp receive_review(ctx, candidate_id, session_id, number, {:error, reason}) do
    provider_output = reviewer_provider_text(reason)
    login = ProviderMarker.login_failure(provider_output)
    marker = ProviderMarker.classify(provider_output)
    retry? = Map.get(ctx, :capacity_retry_count, 0) < length(@capacity_backoff_minutes)

    case {login, marker} do
      {%{"harness" => harness} = login, _} ->
        command = Kogen.Harness.login_command(login_binding(ctx, harness))

        stop(
          ctx,
          "reviewer: #{harness} login rejected (401) (class environment); run `#{command}`",
          %{
            "stop_class" => "environment",
            "provider" => login,
            "next_command" => command,
            "stop_category" => "environment"
          }
        )

      {_, %{"retry" => true} = marker} when retry? ->
        retry_review(ctx, candidate_id, session_id, number, marker)

      {_, %{} = marker} ->
        stop(
          ctx,
          "provider failure during Review (class provider, #{marker["kind"]}): #{marker["marker"]} #{role_label(ctx, :reviewer)}",
          %{"stop_class" => "provider", "provider" => marker}
        )

      {_, nil} ->
        stop(ctx, "Reviewer failure: #{inspect(reason)} #{role_label(ctx, :reviewer)}")
    end
  end

  defp accept_verdict(ctx, candidate_id, session_id, number, verdict, response) do
    case record_verdict(ctx, candidate_id, session_id, verdict, response) do
      {:ok, ctx, response} ->
        if response["verdict"] == "accept" do
          evidence_addendum(ctx, candidate_id, session_id, number, verdict)
        else
          review_rework(ctx, candidate_id, session_id, number, response)
        end

      {:error, reason} ->
        stop(ctx, "Reviewer failure: #{reason} #{role_label(ctx, :reviewer)}", %{
          "invalid_verdict" => verdict.response
        })
    end
  end

  # A validated verdict applied to the record in one update, with its cited
  # references snapshotted; shared by every Review, provisional Review and
  # evidence addendum of both entries.
  defp record_verdict(ctx, candidate_id, session_id, verdict, response) do
    response =
      Review.apply_ledger(response, current_attempt(ctx)["verification_ledger"], ctx.contract)

    with {:ok, references} <- snapshot_references(response, ctx),
         :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, tracking} <-
           Tracking.apply_verdict(ctx.tracking, response, verdict.session_id, references) do
      {:ok,
       %{
         ctx
         | tracking: tracking,
           reviewers: ctx.reviewers ++ [verdict.session_id],
           references: Map.merge(ctx.references, references)
       }
       |> Map.delete(:review_record_bytes), response}
    end
  end

  # A Review rework is one settled round too: its findings count toward the
  # frozen progress allowance before the Developer resumes.
  defp review_rework(ctx, candidate_id, session_id, number, response) do
    cycle = List.last(ctx.execution.state["cycles"]) || %{"candidate_id" => candidate_id}
    no_change? = Map.get(ctx, :review_candidate_id) == candidate_id
    ctx = observe_cycle(ctx, cycle)

    with {:ok, ctx} <-
           note_time(ctx, "review rework"),
         {:ok, ctx} <-
           record_progress(ctx, cycle, Tracking.open_findings(ctx.tracking), no_change?) do
      ctx = Map.put(ctx, :handoff_at_ms, System.os_time(:millisecond))

      rework(
        ctx,
        session_id,
        number,
        "Reviewer findings: " <> Jason.encode!(response) <> handoff_time_line(ctx)
      )
    else
      {:settled, result} ->
        result

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  # The accepting Reviewer is resumed once after settlement, in the same
  # session, with the settled receipts of exactly this tree bound in a
  # second immutable packet. Only its accepting verdict, joined by
  # `AcceptanceJoin` with every settled receipt on the same tree, enters
  # guarded publication; an objection is Review rework.
  defp evidence_addendum(
         %{addendum: %{"candidate_id" => candidate_id}} = ctx,
         candidate_id,
         session_id,
         number,
         verdict
       ) do
    join_and_publish(ctx, candidate_id, session_id, number, verdict)
  end

  defp evidence_addendum(ctx, candidate_id, session_id, number, verdict) do
    case run_addendum(ctx, candidate_id, session_id, verdict.session_id) do
      {:ok, ctx, addendum, result, record_bytes} ->
        receive_addendum(
          ctx,
          candidate_id,
          session_id,
          number,
          verdict,
          addendum,
          result,
          record_bytes
        )

      {:error, ctx, reason} ->
        stop(ctx, reason)
    end
  end

  # The addendum turn itself: a second immutable packet binding every
  # settled receipt of this tree, then one resume of the accepting
  # Reviewer's own session. Its result is received by the caller.
  defp run_addendum(ctx, candidate_id, session_id, reviewer_session) do
    attempt = current_attempt(ctx)
    receipts = attempt_receipts(attempt)
    digests = settled_digests(ctx, receipts)
    started_at = DateTime.utc_now()

    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <- write_addendum_packet(ctx, candidate_id),
         :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id) do
      record_bytes = ctx.tracking.bytes

      result =
        Kogen.Harness.resume_reviewer(
          reviewer_session,
          addendum_prompt(ctx, candidate_id, receipts, digests),
          ctx.config.reviewer.model,
          ctx.config.reviewer.effort,
          reviewer_launch_context(ctx)
        )

      addendum = %{
        "candidate_id" => candidate_id,
        "reviewer_session_id" => reviewer_session,
        "cited_digests" => digests,
        "started_at" => DateTime.to_iso8601(started_at),
        "packet" => current_attempt(ctx)["addendum_packet"]
      }

      {:ok, ctx, addendum, result, record_bytes}
    else
      {:error, reason} -> {:error, ctx, reason}
    end
  end

  defp receive_addendum(
         ctx,
         candidate_id,
         session_id,
         number,
         verdict,
         addendum,
         {:ok, turn},
         record_bytes
       ) do
    if turn.session_id != verdict.session_id do
      stop(
        ctx,
        "Reviewer failure: evidence addendum resumed a different session (expected #{verdict.session_id}, got #{turn.session_id}) #{role_label(ctx, :reviewer)}"
      )
    else
      outcome = if turn.response["verdict"] == "accept", do: "confirm", else: "object"

      addendum =
        Map.merge(addendum, %{"outcome" => outcome, "verdict" => turn.response["verdict"]})

      case record_attempt(ctx, %{"evidence_addendum" => addendum}) do
        {:ok, ctx} ->
          ctx =
            ctx
            |> Map.merge(%{addendum: addendum, review_reasked: false})
            |> Map.put(:review_record_bytes, record_bytes)

          # The addendum verdict is validated like any verdict; accepting
          # returns to `evidence_addendum/5`, which joins and publishes.
          receive_review(
            ctx,
            candidate_id,
            session_id,
            number,
            {:ok, %{turn | session_id: turn.session_id}}
          )

        {:error, reason} ->
          stop(ctx, reason)
      end
    end
  end

  defp receive_addendum(
         ctx,
         _candidate_id,
         _session_id,
         _number,
         _verdict,
         _addendum,
         {:error, reason},
         _record_bytes
       ) do
    text = reviewer_provider_text(reason)

    case ProviderMarker.classify(text) do
      %{} = marker ->
        stop(
          ctx,
          "provider failure during evidence addendum (class provider, #{marker["kind"]}): #{marker["marker"]} #{role_label(ctx, :reviewer)}",
          %{"stop_class" => "provider", "provider" => marker}
        )

      nil ->
        stop(
          ctx,
          "Reviewer failure: evidence addendum: #{inspect(reason)} #{role_label(ctx, :reviewer)}"
        )
    end
  end

  defp addendum_prompt(ctx, candidate_id, receipts, _digests) do
    {live, offline} = settled_split(ctx, receipts)

    line = fn receipt ->
      "  - #{receipt["target"]}: #{receipt_status(receipt)}; log #{receipt["log_path"]} (sha256 #{receipt["log_sha256"]})" <>
        if(receipt["reused_from"], do: "; reused from an exact-binding prior receipt", else: "")
    end

    lines =
      Enum.join(
        ["- offline gate, digest #{receipt_digest(offline)}:" | Enum.map(offline, line)] ++
          Enum.map(
            live,
            &"- #{String.trim_leading(line.(&1))}; receipt digest #{receipt_digest(&1)}"
          ),
        "\n"
      )

    packet = current_attempt(ctx)["addendum_packet"]

    """
    KOGEN_EVIDENCE_ADDENDUM

    Every verification job for Candidate #{candidate_id} has settled. This is the
    evidence addendum to your provisional verdict on this same tree; the tree has not
    changed. The settled receipts are bound in the review packet
    #{Path.expand(packet["path"], ctx.control)} (sha256 #{packet["sha256"]}):

    #{lines}

    Check the settled receipts, their logs and target evidence against every scenario.
    Return a complete verdict in the same schema: `accept` confirms that the settled
    evidence supports your verdict; `rework` objects, with findings naming what the
    evidence does not establish. Do not accept on the strength of a passing status alone.
    """ <> task_context(ctx, candidate_id, "reviewer")
  end

  defp write_addendum_packet(ctx, candidate_id) do
    input = %{
      record: ctx.tracking.record,
      record_path: Tracking.relative_path(ctx.tracking),
      record_bytes: ctx.tracking.bytes,
      candidate_id: candidate_id,
      open_findings: Enum.map(Tracking.open_findings(ctx.tracking), & &1["id"]),
      verification_disclosures: verification_disclosures(ctx)
    }

    name = "#{length(ctx.tracking.record["attempts"]) - 1}-addendum"

    with {:ok, bytes} <- ReviewPacket.build(input),
         {:ok, binding} <-
           ReviewPacket.write(
             ctx.tracking.path,
             name,
             bytes,
             ctx.token,
             candidate_id,
             ctx.control
           ) do
      record_attempt(ctx, %{"addendum_packet" => binding})
    end
  end

  @doc false
  # Canonical digest of one settled receipt, the value the addendum cites
  # and the join compares.
  def receipt_digest(receipt),
    do: Base.encode16(:crypto.hash(:sha256, Jason.encode!(canonical(receipt))), case: :lower)

  # The settled evidence of one tree as the join binds it: one digest for the
  # whole offline gate and one per provider-backed receipt.
  defp settled_split(ctx, receipts),
    do:
      Enum.split_with(
        receipts,
        &(get_in(ctx.catalog, [:targets, &1["target"], "provider_backed"]) == true)
      )

  defp settled_digests(ctx, receipts) do
    {live, offline} = settled_split(ctx, receipts)

    AcceptanceJoin.receipt_digests(%{
      offline: %{sha256: receipt_digest(offline)},
      target_receipts: Enum.map(live, &%{sha256: receipt_digest(&1)})
    })
  end

  defp canonical(map) when is_map(map),
    do: map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> [k, canonical(v)] end)

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  # The single controller join on the final tree: the complete offline gate,
  # every selected live target passed, every scenario satisfied, no open
  # finding, and the accepting addendum verdict of the same Reviewer after
  # settlement, citing exactly the settled receipt digests. Nothing
  # self-reported enters it.
  defp join_and_publish(ctx, candidate_id, session_id, number, verdict) do
    inputs = join_inputs(ctx, candidate_id, verdict)

    case AcceptanceJoin.check(inputs) do
      :ok ->
        case record_attempt(ctx, %{"acceptance_join" => "passed"}) do
          {:ok, ctx} ->
            ctx = Map.delete(ctx, :addendum)

            publish(ctx, candidate_id, session_id, verdict, number)

          {:error, reason} ->
            stop(ctx, reason)
        end

      {:refuse, reasons} ->
        detail =
          Enum.map_join(reasons, "; ", fn {name, value} -> "#{name}: #{inspect(value)}" end)

        stop(ctx, "publication refused by the acceptance join: #{detail}", %{
          "stop_category" => "integrity",
          "acceptance_join" =>
            Enum.map(reasons, fn {name, value} -> [to_string(name), inspect(value)] end)
        })
    end
  end

  defp join_inputs(ctx, candidate_id, verdict) do
    attempt = current_attempt(ctx)
    receipts = attempt_receipts(attempt)
    context = ctx.execution.context_sha256
    cycle = List.last(ctx.execution.state["cycles"]) || %{}
    addendum = attempt["evidence_addendum"] || %{}
    live? = &(get_in(ctx.catalog, [:targets, &1, "provider_backed"]) == true)
    {live, offline} = Enum.split_with(receipts, &live?.(&1["target"]))

    bind = fn receipt ->
      %{
        target: receipt["target"],
        tree: receipt["candidate_id"],
        context_digest: receipt["context_sha256"] || context,
        status: receipt_status(receipt),
        sha256: receipt_digest(receipt)
      }
    end

    offline_status =
      if offline != [] and Enum.all?(offline, &(receipt_status(&1) == "passed")),
        do: "passed",
        else: "failed"

    offline_trees = offline |> Enum.map(& &1["candidate_id"]) |> Enum.uniq()

    %{
      tree: candidate_id,
      frozen_context_digest: frozen_context_digest(ctx),
      context_digest: context,
      offline: %{
        tree: if(offline_trees == [candidate_id], do: candidate_id),
        context_digest: context,
        status: offline_status,
        sha256: receipt_digest(offline)
      },
      selected_targets: Enum.filter(ctx.targets, live?),
      target_receipts: Enum.map(live, bind),
      selected_offline_targets: Enum.reject(ctx.targets, live?),
      offline_target_receipts: Enum.map(offline, bind),
      scenario_ids: scenario_ids(ctx),
      scenarios:
        Map.new(ctx.contract.scenarios, fn scenario ->
          {scenario["id"], scenario_satisfied?(ctx, scenario["id"])}
        end),
      findings:
        Enum.map(
          Tracking.open_findings(ctx.tracking),
          &%{id: &1["id"], blocking: true, status: "open"}
        ),
      verdict: %{
        session: verdict.session_id,
        verdict: addendum["verdict"],
        tree: addendum["candidate_id"],
        provisional: false,
        final: true
      },
      settlement: %{
        seq: timestamp_seq(cycle["finished_at"]),
        tree: cycle["candidate_id"],
        receipt_digests: settled_digests(ctx, receipts)
      },
      addendum: %{
        session: addendum["reviewer_session_id"],
        tree: addendum["candidate_id"],
        seq: timestamp_seq(addendum["started_at"]),
        cited_digests: addendum["cited_digests"],
        outcome: addendum["outcome"]
      }
    }
  end

  defp receipt_status(%{"status" => status}) when is_binary(status), do: status
  defp receipt_status(%{"exit_code" => 0}), do: "passed"
  defp receipt_status(_receipt), do: "failed"

  # From the validated addendum verdict the controller applied to the
  # latest attempt, never from Developer or Reviewer prose.
  defp scenario_satisfied?(ctx, id) do
    current_attempt(ctx)
    |> get_in(["verdict", "scenarios"])
    |> List.wrap()
    |> Enum.any?(&(&1["id"] == id and &1["status"] == "satisfied"))
  end

  defp timestamp_seq(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.to_unix(at, :microsecond)
      _ -> nil
    end
  end

  defp timestamp_seq(_value), do: nil

  # A delivered verdict the Contract rejects (for example an evidence path
  # that does not exist) failed validation too: its first rejection gets the
  # same one re-ask, with the Contract's errors; a second stops the Build,
  # keeping both payloads.
  defp invalid_verdict(ctx, candidate_id, session_id, number, verdict, reason) do
    if ctx[:review_reasked] do
      stop(
        ctx,
        "Reviewer failure: #{reason}, unrepaired on re-ask #{role_label(ctx, :reviewer)}",
        %{
          "invalid_verdict" => ctx[:invalid_verdict] || verdict.response,
          "invalid_verdict_reask" => verdict.response
        }
      )
    else
      details = %{
        "reviewer_session_id" => verdict.session_id,
        "message" => Jason.encode!(verdict.response),
        "errors" => reason |> String.split("; ") |> Enum.map(&%{"pointer" => "", "rule" => &1})
      }

      ctx = Map.merge(ctx, %{review_reasked: true, invalid_verdict: verdict.response})

      case reask_malformed_verdict(ctx, details) do
        {:ok, repaired} ->
          receive_review(ctx, candidate_id, session_id, number, {:ok, repaired})

        {:error, reask_details} ->
          stop(
            ctx,
            "Reviewer failure: #{reason}, unrepaired on re-ask #{role_label(ctx, :reviewer)}",
            %{"invalid_verdict" => verdict.response, "invalid_verdict_reask" => reask_details}
          )
      end
    end
  end

  defp retry_review(ctx, candidate_id, session_id, number, marker) do
    count = Map.get(ctx, :capacity_retry_count, 0)
    minutes = Enum.at(@capacity_backoff_minutes, count)

    case record_attempt(ctx, %{
           "provider_retries" =>
             List.wrap(current_attempt(ctx)["provider_retries"]) ++
               [%{"role" => "reviewer", "marker" => marker, "backoff_minutes" => minutes}]
         }) do
      {:ok, ctx} ->
        capacity_pause(minutes)

        ctx =
          Map.merge(ctx, %{
            review_provider_retried: true,
            review_provider_retry_count: count + 1,
            capacity_retry_count: count + 1,
            review_reasked: false
          })

        prompt =
          render_reviewer_prompt(ctx.intent, candidate_id, ctx.config, ctx.control) <>
            reviewer_notes_section(ctx) <> task_context(ctx, candidate_id, "reviewer")

        context =
          ctx
          |> scrubbed_context(:reviewer)
          |> Kogen.Harness.with_ledger(ledger_paths(ctx))
          |> maybe_with_scenarios(ctx)

        result =
          Kogen.Harness.launch_reviewer(
            prompt,
            ctx.config.reviewer.model,
            ctx.config.reviewer.effort,
            context
          )

        receive_review(ctx, candidate_id, session_id, number, result)

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  # The tail of a failed Review launch, drawn from whatever the adapter's
  # error tuple carries (an `:output_tail`-bearing map, a binary tail, or
  # neither), flattened the same way `provider_text/1` reads Developer
  # transport evidence.
  defp reviewer_provider_text(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.flat_map(&reviewer_provider_text_piece/1)
    |> Enum.join("\n")
  end

  defp reviewer_provider_text(reason), do: inspect(reason)

  defp reviewer_provider_text_piece(value) when is_binary(value), do: [value]
  defp reviewer_provider_text_piece(value) when is_map(value), do: [provider_text(value)]
  defp reviewer_provider_text_piece(_value), do: []

  # Resumes the exact Reviewer session named in `details` once, with the
  # schema errors from the invalid verdict, asking only for a corrected
  # verdict in valid shape. Returns `{:ok, verdict}` only when the repair is
  # schema-valid and keeps the same `verdict` value as the first (parsed)
  # attempt; otherwise `{:error, details}` naming why not (a second invalid
  # verdict's own details, a changed `verdict` value, or no session to
  # resume).
  defp reask_malformed_verdict(ctx, details) do
    session_id = details["reviewer_session_id"]

    if is_binary(session_id) and session_id != "" do
      resume_reviewer_session(ctx, session_id, details)
    else
      {:error, %{"reason" => "no Reviewer session id to resume"}}
    end
  end

  defp resume_reviewer_session(ctx, session_id, details) do
    original_verdict = malformed_verdict_value(details["message"])

    context =
      ctx
      |> scrubbed_context(:reviewer)
      |> Kogen.Harness.with_ledger(ledger_paths(ctx))
      |> maybe_with_scenarios(ctx)

    result =
      Kogen.Harness.resume_reviewer(
        session_id,
        reask_prompt(details),
        ctx.config.reviewer.model,
        ctx.config.reviewer.effort,
        context
      )

    case result do
      {:ok, verdict} ->
        if is_nil(original_verdict) or verdict.response["verdict"] == original_verdict do
          {:ok, verdict}
        else
          {:error,
           %{
             "reason" => "repaired verdict changed its verdict value",
             "verdict" => verdict.response
           }}
        end

      {:error, {:malformed_verdict, _code, reask_details}} ->
        {:error, reask_details}

      {:error, reason} ->
        {:error, %{"reason" => inspect(reason)}}
    end
  end

  defp malformed_verdict_value(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, %{"verdict" => value}} -> value
      _ -> nil
    end
  end

  defp malformed_verdict_value(_message), do: nil

  @doc """
  The one same-session re-ask sent to a Reviewer whose verdict failed
  validation: `details["errors"]` lists each error's JSON pointer and rule.
  """
  def reask_prompt(details) do
    "Your previous verdict did not match the required per-launch schema. Return a " <>
      "corrected verdict in the same shape you were asked for, in the same session, " <>
      "with the same `verdict` value. Do not form a new judgement.\n\n" <>
      "Schema errors:\n" <> Enum.map_join(schema_errors(details), "\n", &error_line/1)
  end

  defp schema_errors(%{"errors" => errors}) when is_list(errors), do: errors
  defp schema_errors(_details), do: []

  defp error_line(%{"pointer" => "", "rule" => rule}), do: "- #{rule}"
  defp error_line(%{"pointer" => pointer, "rule" => rule}), do: "- #{pointer}: #{rule}"
  defp error_line(%{pointer: pointer, rule: rule}), do: "- #{pointer}: #{rule}"
  defp error_line(other), do: "- " <> inspect(other)

  # Every launch takes its role, Expert and native helper profiles
  # from the record's `role_assignment`, frozen once at Build start; nothing
  # is re-derived from `.kogen/config.yaml`.
  @doc false
  def assigned_config(config, %{"role_assignment" => assignment}) do
    roles = Kogen.Intent.roles()
    helpers = Map.fetch!(assignment, "helpers")
    harness = get_in(assignment, ["developer", "harness"])

    native =
      Map.new(helpers, fn {harness, set} ->
        {harness,
         %{scout: assigned_profile(set["scout"]), worker: assigned_profile(set["worker"])}}
      end)

    dominant =
      helpers
      |> Map.fetch!(harness)
      |> Map.new(fn {label, profile} ->
        {String.to_existing_atom(label), assigned_profile(profile)}
      end)

    config
    |> Map.merge(Map.new(roles, &{&1, assigned_profile(assignment[Atom.to_string(&1)])}))
    |> Map.merge(%{
      harness: harness,
      roles: Map.new(roles, &{&1, assignment[Atom.to_string(&1)]["harness"]}),
      native_helpers: native,
      helpers: dominant
    })
  end

  defp assigned_profile(%{"model" => model, "effort" => effort}),
    do: %{model: model, effort: effort}

  # Names the role's frozen harness, model and effort in a role failure.
  defp role_label(ctx, role) do
    profile = Map.fetch!(ctx.config, role)

    "(#{role} on harness #{Kogen.Intent.role_harness(ctx.config, role)}, " <>
      "#{profile.model} at #{profile.effort})"
  end

  # The evidence addendum is the same Reviewer session resumed on purpose.
  defp fresh_reviewer(%{addendum: %{"reviewer_session_id" => reviewer}}, reviewer, developer)
       when reviewer != developer,
       do: :ok

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
      review? = String.starts_with?(reason, "Reviewer findings:")

      if number >= ctx.config.outer_resumptions do
        stop(
          ctx,
          "stopped after #{ctx.config.outer_resumptions} outer resumptions without an accepting Review: #{reason}"
        )
      else
        next_ctx =
          if review? do
            Map.merge(ctx, %{
              review_candidate_id: current_attempt(ctx)["candidate_id"],
              review_nochange_count: 0,
              review_reason: reason
            })
          else
            Map.drop(ctx, [:review_candidate_id, :review_nochange_count, :review_reason])
          end

        begin_attempt(Map.drop(next_ctx, [:addendum]), session_id, number + 1, reason)
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  # The record's `candidate` block is sealed before the summary digest is
  # written into the Complete package, and the summary binds those exact
  # bytes: `published`. A later refusal replaces it with `retained` or `published-retained` and the commit.
  defp publish(ctx, candidate_id, session_id, verdict, number) do
    case time_gate(ctx, "publication") do
      {:ok, ctx} -> publish_gated(ctx, candidate_id, session_id, verdict, number)
      {:stop, result} -> result
    end
  end

  defp publish_gated(ctx, candidate_id, session_id, verdict, number) do
    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <- record_attempt(ctx, %{"reference_snapshots" => ctx.references}),
         {:ok, ctx} <- record_candidate(ctx, "published", nil) do
      attempt = current_attempt(ctx)

      case accept(ctx, candidate_id, session_id, verdict, number, attempt_receipts(attempt)) do
        {:ok, commit} ->
          publish_to_control(ctx, commit)

        {:error, reason} ->
          stop(ctx, reason)
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  # Fast-forward only when the admitted branch has not moved and control is
  # clean; then remove control's ignored Approved copy of this slug and the
  # Candidate worktree, branch and owner record. The harness home is kept.
  defp publish_to_control(ctx, commit) do
    candidate = ctx.candidate
    environment_run = Breakers.environment_state(ctx.control).run

    case Workspace.fast_forward(candidate, commit) do
      :ok ->
        if environment_run != [],
          do: Breakers.write_clear(ctx.tracking.path, "published", environment_run)

        File.rm_rf(Path.join([ctx.control, @approved_base, ctx.slug]))

        case Workspace.remove_published(candidate) do
          :ok -> :ok
          {:error, output} -> cleanup_refused(ctx, commit, output)
        end

      {:refused, reason, current} ->
        refuse_publication(ctx, commit, reason, current, true)

      {:error, reason} ->
        head = Workspace.branch_commit(ctx.control, "HEAD")
        current = Workspace.branch_commit(ctx.control, candidate.admitted_branch)

        if head == commit do
          cleanup_refused(ctx, commit, "control post-merge assertion failed: #{reason}")
        else
          refuse_publication(ctx, commit, reason, current)
        end
    end
  end

  # The admitted branch stays published; the Candidate is kept for the
  # Shaper. The record version the Complete summary binds is retained as a
  # sidecar before the disposition changes.
  defp cleanup_refused(ctx, commit, output) do
    candidate = ctx.candidate
    version_note = ""
    Workspace.update_status(candidate, "published: cleanup refused: #{output}", commit)

    suffix =
      case record_candidate(ctx, "published-retained", commit) do
        {:ok, _ctx} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    IO.puts(
      :stderr,
      "warning: published #{commit} on #{candidate.admitted_branch}, but the Candidate worktree was not removed: #{output}. " <>
        "Worktree #{candidate.path}, branch #{candidate.branch}; tracking record: #{ctx.tracking.path}#{version_note}#{suffix}. " <>
        "Remove it with `mix kogen.candidates.remove #{candidate.build_id}`."
    )

    :ok
  end

  # `definite?` means the fast-forward itself refused, so nothing was
  # published whatever HEAD is; only an ambiguous error can be interrupted.
  defp refuse_publication(ctx, commit, reason, current, definite? \\ false) do
    candidate = ctx.candidate
    version_note = ""
    head = Workspace.branch_commit(ctx.control, "HEAD")

    {suffix, ctx} =
      case record_candidate(ctx, "retained", commit) do
        {:ok, updated} -> {"", updated}
        {:error, error} -> {"; tracking persistence/integrity failure: #{error}", ctx}
      end

    category =
      if definite? or head == candidate.admitted_commit,
        do: "accepted-unpublished",
        else: "publication-interrupted"

    report = FailureReport.record_failure(ctx, category, reason)
    report_suffix = report_suffix(report, category, ctx.tracking.path)
    custody = return_terminal_package(ctx.control, report)

    Workspace.update_status(candidate, "#{category}: #{reason}", commit)

    message =
      if category == "accepted-unpublished",
        do: "Accepted Candidate not published: #{reason}.",
        else:
          "Publication outcome is unresolved after control moved to #{head || "(missing)"}: #{reason}."

    {:error,
     "#{message} Admitted #{candidate.admitted_branch} at #{candidate.admitted_commit}; current #{current || "(missing)"}. " <>
       control_publication_state(candidate, head) <>
       " " <>
       "Worktree #{candidate.path}, branch #{candidate.branch}, Candidate commit #{commit}; tracking record: #{ctx.tracking.path}#{version_note}#{suffix}. " <>
       "Fast-forward #{candidate.admitted_branch} yourself after tidying the control checkout, or discard it with " <>
       "`mix kogen.candidates.remove #{candidate.build_id} --discard-accepted`.#{report_suffix}#{custody}"}
  end

  defp control_publication_state(candidate, head) when head == candidate.admitted_commit,
    do: "Control HEAD remains at the admitted commit; publication did not advance it."

  defp control_publication_state(_candidate, head),
    do: "Control HEAD is #{head || "(missing)"}; inspect control before retrying publication."

  defp record_candidate(%{candidate: nil} = ctx, _disposition, _commit), do: {:ok, ctx}

  defp record_candidate(ctx, disposition, commit) do
    record =
      ctx.tracking.record
      |> Map.put("candidate", Workspace.record_block(ctx.candidate, disposition, commit))
      |> put_boundary(ctx.boundary)

    with {:ok, tracking} <- Tracking.update(ctx.tracking, record) do
      {:ok, %{ctx | tracking: tracking}}
    end
  end

  defp put_boundary(record, nil), do: record

  defp put_boundary(record, boundary),
    do: Map.put(record, "boundary", WriteBoundary.record_block(boundary))

  defp inputs_unchanged(ctx) do
    with :ok <- Tracking.verify(ctx.tracking),
         :ok <- approved_unchanged(ctx),
         do: remaining_inputs_unchanged(ctx)
  end

  # The same checks at a Developer handoff, where entries added to the
  # Candidate's Approved copy are returned for rework rather than stopping;
  # every later check still runs, so an addition never hides a terminal one.
  defp handoff_inputs_unchanged(ctx) do
    with :ok <- Tracking.verify(ctx.tracking),
         {:ok, added} <- approved_additions(ctx),
         :ok <- remaining_inputs_unchanged(ctx),
         do: {:ok, added}
  end

  defp approved_additions(ctx) do
    case approved_state(ctx) do
      :ok -> {:ok, []}
      {:added, paths} -> {:ok, paths}
      {:error, _} = error -> error
    end
  end

  defp remaining_inputs_unchanged(ctx) do
    with :ok <- references_unchanged(ctx.references, ctx),
         :ok <- Tracking.verify_record_versions(ctx.tracking),
         :ok <- Tracking.verify_artifacts(ctx.tracking),
         :ok <- review_packets_unchanged(ctx),
         :ok <- Ledger.verify(current_attempt(ctx)["verification_ledger"], ctx.control) do
      target_evidence_unchanged(ctx.tracking, ctx.root)
    end
  end

  defp bound_inputs_unchanged(ctx, candidate_id, _session_id) do
    with :ok <- inputs_unchanged(ctx),
         {:ok, actual} <- Kogen.Git.candidate_id(ctx.root) do
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

  defp login_binding(ctx, harness) do
    binding = get_in(ctx, [:bindings, harness]) || get_in(ctx, [:bindings, to_string(harness)])

    case binding do
      binding when is_map(binding) -> binding
      _ -> %{harness: harness}
    end
  end

  defp current_attempt(ctx), do: List.last(ctx.tracking.record["attempts"])

  defp budget_state(ctx) do
    execution = Map.get(ctx, :execution)
    context = execution && (execution[:context] || execution["context"])
    state = execution && (execution[:state] || execution["state"])
    state_path = execution && (execution[:state_path] || execution["state_path"])

    if is_map(context) and is_map(state) and is_binary(state_path) and File.exists?(state_path) do
      bytes = File.read!(state_path)

      %{
        "outer_attempt" => current_attempt(ctx)["number"] || context["outer_attempt"],
        "offline_retries" => context["offline_retries"],
        "verification_retries" => context["verification_retries"],
        "offline_failures" => state["offline_failures"] || 0,
        "failures_since_pass" => state["failures_since_pass"] || 0,
        "terminal_state" => state["terminal_state"],
        "state" => Path.relative_to(state_path, Path.expand(ctx.control)),
        "state_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      }
    end
  rescue
    _ -> nil
  end

  defp record_attempt(ctx, changes) do
    record = ctx.tracking.record
    attempts = List.update_at(record["attempts"], -1, &Map.merge(&1, changes))
    updated_record = record |> Map.put("attempts", attempts) |> maybe_failed(changes)

    with {:ok, tracking} <- Tracking.update(ctx.tracking, updated_record) do
      ctx = %{ctx | tracking: tracking}
      notify_record(ctx)
      {:ok, ctx}
    end
  end

  # A provisional Review job reports every record it wrote to the waiting
  # controller at once, so the controller keeps the newest tracking state
  # even when the job is cancelled or dies before it returns.
  defp notify_record(%{record_sink: {pid, ref}} = ctx),
    do: send(pid, {:kogen_provisional_record, ref, provisional_patch(ctx)})

  defp notify_record(_ctx), do: :ok

  defp maybe_failed(record, %{"status" => "failed"}), do: Map.put(record, "status", "failed")
  defp maybe_failed(record, _changes), do: record

  # Every stop keeps the Candidate worktree, branch and harness home exactly
  # as they are, marks the owner record `stopped: <category>` and names the
  # Candidate next to the tracking record. A `stop_category` detail names the
  # category explicitly; otherwise the prefix table below classifies it.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp stop(ctx, reason, details \\ %{}) do
    category = details["stop_category"] || stop_category(reason)
    changes = Map.merge(details, %{"status" => "failed", "failure" => reason})

    changes =
      if budget_state(ctx), do: Map.put(changes, "budget_state", budget_state(ctx)), else: changes

    {result, final_ctx} =
      case ctx.tracking.record["attempts"] do
        [] ->
          case record_candidate(ctx, "retained", nil) do
            {:ok, updated} -> {{:ok, updated}, updated}
            {:error, error} -> {{:error, error}, ctx}
          end

        _attempts ->
          case record_attempt(ctx, changes) do
            {:ok, updated} ->
              case record_candidate(updated, "retained", nil) do
                {:ok, final} -> {{:ok, final}, final}
                {:error, error} -> {{:error, error}, updated}
              end

            {:error, error} ->
              {{:error, error}, ctx}
          end
      end

    report_result = FailureReport.record_failure(final_ctx, category, reason, details)
    custody = return_terminal_package(final_ctx.control, report_result)

    suffix =
      case result do
        {:ok, _ctx} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    ids = Enum.map_join(ctx.contract.scenarios, ", ", & &1["id"])
    report_suffix = report_suffix(report_result, category, final_ctx.tracking.path)

    {:error,
     "#{reason}#{suffix}; unresolved scenarios: #{ids}; tracking record: #{final_ctx.tracking.path}" <>
       report_suffix <> custody <> retained(final_ctx, category)}
  end

  @doc """
  The frozen context a run binds: route and role matrix, Approved package,
  catalog and admission base, all read from the tracking record and the
  admission catalog. A config edit after admission cannot change it.
  """
  def frozen_context_digest(ctx) do
    record = ctx.tracking.record

    %{
      "route" => record["route"],
      "role_assignment" => record["role_assignment"],
      "approved_package_digest" => record["approved_package_digest"],
      "catalog_sha256" => ctx.catalog[:sha256],
      "base_commit" => ctx.base_commit
    }
    |> canonical()
    |> Jason.encode!()
    |> then(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
  end

  defp return_terminal_package(control, {:ok, report_path}) do
    case FailureReport.return_to_draft(control, report_path) do
      :ok -> ""
      {:error, reason} -> "; " <> reason
    end
  end

  defp return_terminal_package(_control, _report), do: ""

  defp report_suffix({:ok, path}, category, _record_path) do
    {action, command} = action_for_report(category, path)
    command_suffix = if is_binary(command) and command != "", do: " (#{command})", else: ""
    "; category: #{category}; failure report: #{path}; next action: #{action}#{command_suffix}"
  end

  defp report_suffix(_, _category, _record_path), do: ""

  defp action_for_report(category, path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{"next_action" => action} = report} -> {action, report["next_command"]}
          _ -> {elem(FailureReport.classify(category), 1), nil}
        end

      _ ->
        {elem(FailureReport.classify(category), 1), nil}
    end
  end

  defp retained(%{candidate: nil}, _category), do: ""

  defp retained(ctx, category) do
    Workspace.update_status(ctx.candidate, "stopped: #{category}")
    "; " <> Workspace.retained_description(ctx.candidate)
  end

  @stop_categories [
    {"time budget exhausted", "time-budget"},
    {@approved_changed, "integrity"},
    {"verification retries exhausted", "verification-exhausted"},
    {"offline retries exhausted", "offline-exhausted"},
    {"environment failure", "environment"},
    {"provider failure", "provider"},
    {"Candidate unchanged since failed cycle", "unchanged-candidate"},
    {"stopped after ", "outer-allowance-exhausted"},
    {@cannot_comply_prefix, "cannot-comply"},
    {"harness failure", "provider-failure"},
    {"resume created a new session", "provider-failure"},
    {"Reviewer failure", "review-failure"},
    {"write boundary", "write-boundary"},
    {"commit failed", "publication-failed"},
    {"publication", "publication-failed"}
  ]

  defp stop_category(reason) do
    Enum.find_value(@stop_categories, "integrity", fn {prefix, category} ->
      if String.starts_with?(reason, prefix) or
           (prefix in ["write boundary", "publication"] and String.contains?(reason, prefix)),
         do: category
    end)
  end

  # Receipts are one uniform list; records written before it keep separate
  # `check` and `targets` fields.
  defp attempt_receipts(%{"receipts" => receipts}) when is_list(receipts), do: receipts

  defp attempt_receipts(attempt),
    do: Enum.reject([attempt["check"] | Map.get(attempt, "targets", [])], &is_nil/1)

  defp scenario_receipts(ctx) do
    receipts = attempt_receipts(current_attempt(ctx))

    Map.new(ctx.contract.scenarios, fn scenario ->
      {scenario["id"], Enum.filter(receipts, &(&1["target"] in scenario["verified_by"]))}
    end)
  end

  defp developer_prompt(ctx, nil) do
    base =
      render_developer_prompt(ctx.intent, ctx.contract.text, ctx.targets, ctx.config, roots(ctx))

    base <> first_failure_prompt_block(ctx) <> task_context(ctx, nil, "developer")
  end

  defp developer_prompt(ctx, reason) do
    base =
      render_developer_prompt(
        ctx.intent,
        ctx.contract.text,
        ctx.targets,
        ctx.config,
        roots(ctx)
        |> Map.put(:changed_paths, [])
        |> Map.put(:readiness_focus, "following rework feedback")
      )

    if ctx.continuation do
      base <> continuation_prompt_block(ctx) <> task_context(ctx, nil, "developer")
    else
      base <> "\n\n" <> resume_feedback(ctx, reason) <> task_context(ctx, nil, "developer")
    end
  end

  defp continuation_prompt_block(ctx) do
    old = ctx.continuation
    report = old.report
    record = Path.expand(old.record_path)

    first =
      case report["signature"] do
        %{"source" => source, "target" => target} = signature
        when source != "stop" and is_binary(target) ->
          FailureHandoff.first_failure_block(signature)

        _ ->
          ""
      end

    "\n\nContinuing Build #{old.id} after it stopped (category: #{report["category"]}; record: #{record}).\n" <>
      "Receipts from before this continuation are discarded: the controller verifies the Candidate again after your turn, and a fresh Reviewer reviews it.\n" <>
      first
  end

  defp roots(ctx), do: %{control: ctx.control, candidate: ctx.root}

  defp first_failure_prompt_block(ctx) do
    digest =
      Breakers.contract_digest(Path.join([ctx.control, @approved_base, ctx.slug]), ctx.intent.id)

    case Breakers.latest_item_report(ctx.control, ctx.intent.id, digest) do
      %{path: path, report: report} ->
        signature = report["signature"] || %{}

        if signature["source"] == "stop" or not is_binary(signature["target"]) do
          ""
        else
          FailureHandoff.first_failure_block(signature) <>
            "Previous failure report: #{path}\n"
        end

      _ ->
        ""
    end
  end

  # Role-facing control locators are absolute, so they open from the
  # Candidate cwd; `control_root` resolves the control-relative locators the
  # record and the review packet hold.
  defp task_context(ctx, candidate_id, role) do
    context = %{
      "version" => 1,
      "role" => role,
      "working_directory" => ctx.root,
      "control_root" => ctx.control,
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
  @packet_statement "Start from the review packet: it is your evidence source, bound to this attempt and Candidate. Inspect its verification_disclosures as advisory context only; declared test names and path mappings are not proof. Inspect its distinct repair_disclosures section, actual extra-path hunks and Developer rationale; judge feature relevance and whether any test assertion was weakened to conceal failure. Unknown before/after evidence remains unknown. A cut or left-out item carries its digest and a record locator. The full tracking record is an audit locator only; never dump it whole. The packet never replaces inspecting the Candidate: read any Candidate file and run read-only commands."
  @jev_statement "Jev only read the Developer's words and never judged the code. Its readings are advisory, never findings or verification; a confident \"unfinished\" reading never routes rework by itself, only your verdict does."
  @changes_statement "`changed_affected_paths` lists files that changed relative to HEAD, not where each behaviour lives."

  defp reviewer_context(ctx) do
    jev = current_attempt(ctx)["jev"] || %{}

    %{
      "evidence_source" => "review_packet",
      "review_packet" =>
        ctx.review_packet
        |> Map.take(["path", "sha256", "byte_count"])
        |> Map.put("path", packet_path(ctx)),
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
          "Review packet: `#{packet_path(ctx)}` (#{ctx.review_packet["byte_count"]} bytes, sha256 #{ctx.review_packet["sha256"]}). " <>
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

  defp packet_path(ctx), do: Path.expand(ctx.review_packet["path"], ctx.control)

  # Ordinary citations are Candidate-relative and read under the Candidate
  # root; a citation of this Build's own record (named absolutely, or
  # relative to either root) keeps its control-relative locator.
  defp snapshot_references(value, ctx) do
    value
    |> collect_references()
    |> Enum.map(&citation_key(&1, ctx))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      case snapshot_reference(path, ctx) do
        {:ok, snapshot} ->
          {:cont, {:ok, Map.put(acc, path, snapshot)}}

        {:error, reason} when is_binary(reason) ->
          {:halt, {:error, "could not retain reference #{path}: #{reason}"}}

        {:error, reason} ->
          {:halt, {:error, "could not retain reference #{path}: #{inspect(reason)}"}}
      end
    end)
  end

  defp citation_key(path, ctx) do
    record = Path.expand(ctx.tracking.path)

    if Path.expand(path, ctx.root) == record or Path.expand(path, ctx.control) == record,
      do: Tracking.relative_path(ctx.tracking),
      else: Path.relative_to(Path.expand(path, ctx.root), ctx.root)
  end

  defp reference_path(key, ctx) do
    if key == Tracking.relative_path(ctx.tracking),
      do: ctx.tracking.path,
      else: Path.expand(key, ctx.root)
  end

  # A citation of this Build's own record keeps metadata and an immutable
  # sidecar of the exact cited version, never an inline copy of the record.
  defp snapshot_reference(path, ctx) do
    tracking = ctx.tracking

    if reference_path(path, ctx) == tracking.path do
      Tracking.retain_record_version(tracking, Map.get(ctx, :review_record_bytes, tracking.bytes))
    else
      with {:ok, bytes} <- File.read(reference_path(path, ctx)) do
        Tracking.retain_artifact(tracking, "fixed_file", path, bytes)
      end
    end
  end

  defp verification_disclosures(ctx) do
    changed_paths = Kogen.Git.changed_paths(ctx.root)

    VerificationPlan.review_disclosures(
      ctx.contract.scenarios,
      ctx.plan,
      ctx.catalog,
      changed_paths,
      ctx.root
    )
  end

  defp collect_references(%{"path" => path, "locator" => _locator}), do: [path]

  defp collect_references(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&collect_references/1)

  defp collect_references(list) when is_list(list), do: Enum.flat_map(list, &collect_references/1)
  defp collect_references(_value), do: []

  defp references_unchanged(references, ctx) do
    Enum.reduce_while(references, :ok, fn {path, snapshot}, :ok ->
      case Tracking.verify_reference(ctx.tracking, reference_path(path, ctx), snapshot) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp target_evidence_unchanged(tracking, root) do
    tracking.record["attempts"]
    |> Enum.flat_map(fn attempt ->
      direct = attempt_receipts(attempt)

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
      case TargetEvidence.verify(snapshot, root) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "bound target evidence changed: #{reason}"}}
      end
    end)
  end

  # Publication writes the Complete package from the frozen Approved bytes
  # into the Candidate, adds noncolliding generated evidence and commits
  # there. A failed stage/commit restores the Candidate's Approved copy from
  # controller memory, never from a Complete copy that an external Git hook
  # might have changed. Control is untouched until `publish_to_control/2`.
  defp accept(ctx, candidate_id, session_id, verdict, resumptions_used, receipts) do
    with :ok <- approved_unchanged(ctx),
         :ok <- check_complete_absent(ctx.control, ctx.slug),
         :ok <- check_complete_absent(ctx.root, ctx.slug) do
      do_accept(ctx, candidate_id, session_id, verdict, resumptions_used, receipts)
    end
  rescue
    error in File.Error ->
      restore_approved_after_failed_commit(ctx, Path.join([ctx.root, @complete_base, ctx.slug]))
      {:error, "publication failed, Approved Intent restored: #{Exception.message(error)}"}
  end

  defp do_accept(ctx, candidate_id, session_id, verdict, resumptions_used, receipts) do
    %{slug: slug, intent: intent} = ctx
    complete_relative = Path.join(@complete_base, slug)
    approved_relative = Path.join(@approved_base, slug)
    complete_dir = Path.join(ctx.root, complete_relative)
    approved_dir = Path.join(ctx.root, approved_relative)
    record_path = Tracking.relative_path(ctx.tracking)

    File.mkdir_p!(Path.dirname(complete_dir))

    case Workspace.write_entries(complete_dir, ctx.approved_entries) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: :eio,
          action: "write Complete package (#{reason})",
          path: complete_dir
    end

    evidence =
      evidence_markdown(
        intent,
        candidate_id,
        session_id,
        verdict,
        resumptions_used,
        receipts,
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
        "\n## Exact evidence\n\n[Compact Build summary](#{summary_name}) contains concise results. The full controller record remains local at `#{record_path}` and is not committed. From the checkout root, verify it with `shasum -a 256 #{record_path}` and compare the digest and byte count in the summary. A fresh clone contains the contract and concise results only; if that archive was cleaned up, exact evidence is unavailable and must not be inferred from this summary or fetched from another Build. A digest identifies bytes; it does not prove semantic inspection.\n"
    )

    File.rm_rf!(approved_dir)

    trailers = [{"Kogen-Intent-ID", intent.id}, {"Kogen-Intent", slug}]

    allowed_paths = [complete_relative <> "/", approved_relative <> "/"]

    expected_entries = package_entries(complete_dir, "")

    publication = %{
      complete_relative: complete_relative,
      approved_relative: approved_relative,
      complete_dir: complete_dir,
      approved_dir: approved_dir,
      entries: expected_entries,
      allowed_paths: allowed_paths
    }

    result = finish_publication(ctx, candidate_id, trailers, publication)

    case result do
      {:ok, commit} ->
        {:ok, commit}

      {:error, {:before_commit, reason}} ->
        restore_approved_after_failed_commit(ctx, complete_dir)

        {:error,
         "commit failed or final staged tree did not match Candidate, Approved Intent restored, no Commit made: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_publication(ctx, candidate_id, trailers, publication) do
    root = ctx.root

    with :ok <- publication_unchanged(ctx, publication),
         {:ok, publication_id} <- Kogen.Git.candidate_id(root),
         :ok <-
           Kogen.Git.stage_and_verify_candidate(candidate_id, publication.allowed_paths, root),
         :ok <- Kogen.Git.assert_staged_tree(publication_id, root),
         :ok <- Kogen.Git.validate_staged_publication(root),
         :ok <- publication_unchanged(ctx, publication),
         subject = Map.get(ctx.intent, :commit_subject) || ctx.intent.title,
         {:ok, head} <- Kogen.Git.commit_staged(subject, trailers, root) do
      with :ok <- Kogen.Git.assert_head_tree(publication_id, root),
           :ok <- publication_unchanged(ctx, publication) do
        {:ok, head}
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
        prefix = publication.approved_relative <> "/"

        published_path =
          if String.starts_with?(path, prefix),
            do: publication.complete_relative <> "/" <> String.replace_prefix(path, prefix, ""),
            else: path

        {published_path, snapshot}
      end)

    with :ok <- Tracking.verify(ctx.tracking),
         :ok <- references_unchanged(references, ctx),
         :ok <- Tracking.verify_record_versions(ctx.tracking),
         :ok <- Tracking.verify_artifacts(ctx.tracking),
         :ok <- review_packets_unchanged(ctx),
         :ok <- target_evidence_unchanged(ctx.tracking, ctx.root) do
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
    approved_dir = Path.join([ctx.root, @approved_base, ctx.slug])
    File.rm_rf!(approved_dir)
    Workspace.write_entries(approved_dir, ctx.approved_entries)
    File.rm_rf!(complete_dir)

    case Kogen.Git.reject_candidate_blinding_index_flags(ctx.root) do
      :ok -> Kogen.Git.unstage_all(ctx.root)
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
      "role_assignment" => record["role_assignment"],
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
        "path" => Tracking.relative_path(ctx.tracking),
        "sha256" => Base.encode16(:crypto.hash(:sha256, ctx.tracking.bytes), case: :lower),
        "byte_count" => byte_size(ctx.tracking.bytes)
      }
    }
  end

  defp summary_attempt(attempt) do
    receipts = attempt_receipts(attempt)

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
            "session_id",
            "cycle_sequence",
            "reused_from"
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

  defp role_harnesses(route) do
    Enum.map_join(Kogen.Intent.roles(), ", ", fn role ->
      profile = Map.fetch!(route, role)

      "#{role} `#{Kogen.Intent.role_harness(route, role)}` " <>
        "(`#{profile.model}` at `#{profile.effort}`)"
    end)
  end

  defp evidence_markdown(
         intent,
         candidate_id,
         developer_session_id,
         verdict,
         resumptions_used,
         receipts,
         route
       ) do
    findings_text = Enum.map_join(verdict.findings, ", ", &Map.get(&1, "id", "finding"))
    findings_text = if findings_text == "", do: "(none)", else: findings_text

    bodies =
      Enum.map_join(receipts, "\n", fn receipt ->
        reuse =
          case receipt["reused_from"] do
            %{"cycle_sequence" => cycle} -> "; reused from cycle #{cycle}"
            _ -> ""
          end

        "- `make #{receipt["target"]}`: `#{receipt["status"]}` (exit_code `#{receipt["exit_code"]}`, " <>
          "cycle #{receipt["cycle_sequence"]}, finished_at `#{receipt["finished_at"]}`, " <>
          "session_id `#{receipt["session_id"] || receipt["developer_session_id"]}`#{reuse})"
      end)

    check_section =
      "## Verification receipts (controller-owned, bound to this Candidate)\n\n" <>
        "Exact output remains in the full local record and its retained logs.\n\n" <>
        bodies <> "\n"

    targets_section = ""

    """
    # Complete evidence: #{intent.title}

    - Route: `#{route.route}` (harness `#{route.harness}`)
    - Role harnesses: #{role_harnesses(route)}
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
  # The prompt, catalog and Approved contract are control-side; the changed
  # paths are the Candidate's. The historical four-argument form, used by
  # prompt fixtures outside a Build, reads both from the process cwd.
  # credo:disable-for-lines:50 Credo.Check.Refactor.Nesting
  def render_developer_prompt(intent, scenarios_text, targets, config, roots \\ nil)

  def render_developer_prompt(intent, scenarios_text, targets, config, nil) do
    cwd = File.cwd!()

    render_developer_prompt(intent, scenarios_text, targets, config, %{
      control: cwd,
      candidate: cwd
    })
  end

  def render_developer_prompt(intent, _scenarios_text, targets, config, roots) do
    changed =
      Map.get_lazy(roots, :changed_paths, fn ->
        case Kogen.Git.changed_paths(roots.candidate) do
          {:ok, paths} -> paths
          _ -> []
        end
      end)

    revision =
      case Kogen.Git.candidate_id(roots.candidate) do
        {:ok, tree} -> tree
        _ -> "unavailable"
      end

    readiness =
      with {:ok, catalog} <- VerificationPlan.load(roots.control),
           {:ok, contract} <-
             Contract.load(
               Path.join([roots.control, @approved_base, intent.slug]),
               roots.control
             ),
           {:ok, plan} <-
             VerificationPlan.build(
               contract.scenarios,
               intent.may_change_guarded_paths,
               catalog,
               roots.control,
               added: Enum.reject(added_targets(intent), &Map.has_key?(catalog.targets, &1))
             ) do
        VerificationPlan.readiness_commands(plan, changed, roots.candidate)
      else
        {:error, reason} -> raise ArgumentError, "developer readiness plan unavailable: #{reason}"
      end

    roots.control
    |> Path.join("priv/kogen/prompts/developer.md")
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
    |> String.replace(
      "{{readiness_scope}}",
      "revision #{revision}; changed paths: #{if(changed == [], do: "none", else: Enum.join(changed, ", "))}; focus: #{Map.get(roots, :readiness_focus, "current Candidate")}"
    )
    |> String.replace(
      "{{execution_policy}}",
      execution_policy(config, "developer", roots.control)
    )
  end

  # The maintained policy text is a control-side engine asset, read from the
  # named control root. Never change the VM-wide working directory for it:
  # concurrent callers (and loading test files) resolve relative paths there.
  defp execution_policy(config, role, control),
    do: Kogen.ExecutionPolicy.render(config, role, control)

  defp resume_feedback(ctx, reason) do
    findings =
      Tracking.open_findings(ctx.tracking)
      |> Enum.map_join("\n", fn finding ->
        "- #{finding["id"]}: #{finding["summary"] || finding["description"] || inspect(finding)}"
      end)

    detail =
      if String.starts_with?(reason, "Reviewer findings:"),
        do: "",
        else: "Current reason: #{reason}\n"

    "Rework required (category: #{failure_category(reason)}; record: #{ctx.tracking.path}).\n" <>
      detail <>
      if(findings == "", do: "", else: "Open Review findings:\n#{findings}\n") <>
      "Select the current attempt by its supplied token.\n"
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
  def render_reviewer_prompt(intent, candidate_id, config, control \\ nil) do
    (control || File.cwd!())
    |> Path.join("priv/kogen/prompts/reviewer.md")
    |> File.read!()
    |> String.replace("{{intent_title}}", intent.title)
    |> String.replace("{{intent_id}}", intent.id)
    |> String.replace("{{approved_path}}", Path.join(@approved_base, intent.slug))
    |> String.replace("{{candidate_id}}", candidate_id)
    |> String.replace(
      "{{execution_policy}}",
      execution_policy(config, "reviewer", control || File.cwd!())
    )
  end
end
