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
      Kogen.Jev
    ],
    exports: [Workspace, WriteBoundary]

  alias Kogen.Build.{
    BaseWorkspace,
    Contract,
    FailureSignature,
    GuardedPaths,
    Ledger,
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

  # Removed from every Developer, Reviewer and target child, including when
  # this controller itself inherited one from an outer Build's Stop runner.
  @context_variables ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_TRACKING_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT)
  # Removed from every role launch, so a role's compile uses the Candidate's
  # own `deps/` and `_build/`, never control's.
  @mix_redirection ~w(MIX_BUILD_PATH MIX_DEPS_PATH MIX_EXS)

  @lock_path ".kogen/build.lock"
  @config_path ".kogen/config.yaml"
  @approved_base ".kogen/intents/approved"
  @complete_base ".kogen/intents/complete"
  @publication_file_limit 5_242_880
  @publication_total_limit 10_485_760
  # Every harness a Build role may use is ready before any launch; the Expert
  # may be consulted from the Developer's harness through `mix kogen.expert`.
  @build_roles [:developer, :reviewer, :expert]

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
    with {:ok, control} <- control_checkout(control),
         {:ok, config} <- Kogen.Intent.read_config(Path.join(control, @config_path), route),
         {:ok, intent} <- Kogen.Intent.read(slug, Path.join(control, @approved_base)),
         {:ok, approved_entries} <- read_approved_entries(control, slug),
         :ok <- preflight_approved_budget(approved_entries),
         :ok <- Kogen.Git.reject_candidate_blinding_index_flags(control),
         :ok <- check_clean_worktree(control),
         {:ok, branch} <- Kogen.Git.current_branch(control),
         {:ok, commit} <- Kogen.Git.head_sha(control),
         :ok <- check_complete_absent(control, slug),
         :ok <- Kogen.Jev.key_present(),
         {:ok, boundary_mode} <- WriteBoundary.admission_mode() do
      admission = %{control: control, branch: branch, commit: commit, boundary: boundary_mode}

      case acquire_lock(control) do
        :ok ->
          try do
            do_build(admission, slug, intent, config, approved_entries)
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
  defp read_approved_entries(root, slug) do
    {:ok, package_entries(Path.join([root, @approved_base, slug]), "")}
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

  # Control's package and the Candidate's copy must both still be the frozen
  # bytes; the controller's memory remains the authority.
  defp approved_unchanged(ctx) do
    with {:ok, entries} when entries == ctx.approved_entries <-
           read_approved_entries(ctx.control, ctx.slug),
         {:ok, entries} when entries == ctx.approved_entries <-
           read_approved_entries(ctx.root, ctx.slug) do
      :ok
    else
      _ -> {:error, "Approved Intent changed during Build; stopped without publication"}
    end
  end

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

  # The lock names this OS process (and, once admitted, the build id) so the
  # Candidate commands can tell a live Build from a stale `running` record.
  defp acquire_lock(control) do
    path = Path.join(control, @lock_path)
    File.mkdir_p(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.binwrite(io, Jason.encode!(%{"pid" => os_pid()}))
        File.close(io)
        :ok

      {:error, :eexist} ->
        {:error, "build lock already present: #{@lock_path}"}

      {:error, reason} ->
        {:error, "could not acquire build lock: #{inspect(reason)}"}
    end
  end

  defp claim_lock(control, build_id) do
    File.write(
      Path.join(control, @lock_path),
      Jason.encode!(%{"pid" => os_pid(), "build_id" => build_id})
    )
  end

  defp os_pid, do: System.pid() |> String.to_integer()

  defp release_lock(control) do
    File.rm(Path.join(control, @lock_path))
    :ok
  end

  @doc "Environment entries that remove every verification or tracking context from a child."
  def context_scrub, do: Enum.map(@context_variables, &{&1, nil})

  # The static, unchanging-for-the-whole-Build inputs, bundled so the
  # settle/review/rework chain below stays under a sane arity as it
  # threads per-attempt state (candidate id, session id, resumption count,
  # Check record, target results) through the loop.
  defp do_build(admission, slug, intent, config, approved_entries) do
    control = admission.control
    added = added_targets(intent)
    guard_targets = catalog_guard_targets(added)

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
         {:ok, bindings} <- Kogen.Harness.bindings(config, @build_roles, control),
         {:ok, tracking} <- Tracking.new(intent, contract, approved_entries, config, control) do
      ctx = %{
        slug: slug,
        intent: intent,
        config: config,
        contract: contract,
        targets: plan.targets,
        plan: plan,
        catalog: catalog,
        base_commit: admission.commit,
        workspace: nil,
        guarded_snapshot: nil,
        policy_environment: nil,
        approved_entries: approved_entries,
        tracking: tracking,
        token: nil,
        reviewers: [],
        references: %{},
        review_packet: nil,
        runtime: nil,
        control: control,
        root: nil,
        candidate: nil,
        boundary: nil,
        bindings: bindings,
        guard_targets: guard_targets.(catalog)
      }

      admit_candidate(ctx, admission)
    else
      {:error, _reason} = error -> error
    end
  end

  # One Candidate and one harness home per Build, created before any launch.
  # The build id is the tracking record id.
  defp admit_candidate(ctx, admission) do
    build_id = ctx.tracking.path |> Path.dirname() |> Path.basename()
    claim_lock(ctx.control, build_id)

    workspace =
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

    suffix =
      case Tracking.update(ctx.tracking, record) do
        {:ok, _tracking} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    {:error, "#{reason}#{suffix}; tracking record: #{ctx.tracking.path}"}
  end

  # Boundary, readiness and base workspace, in that order: a boundary that
  # cannot be applied stops before any readiness call, and readiness runs
  # with the Build's own launch environment inside the boundary.
  defp run_in_candidate(ctx, admission) do
    steps = [
      &apply_boundary(&1, admission.boundary),
      &record_candidate(&1, "running", nil),
      &preflight_candidate/1,
      &capture_candidate/1,
      &admit_base_workspace/1,
      &open_roles/1
    ]

    case Enum.reduce_while(steps, {:ok, ctx}, &admission_step/2) do
      {:ok, ctx} ->
        config = assigned_config(ctx.config, ctx.tracking.record)
        runtime = %{ctx.runtime | route: config}

        ctx = %{
          ctx
          | config: config,
            runtime: runtime,
            policy_environment: Kogen.VerificationPolicy.environment(ctx.guard_targets, ctx.root)
        }

        try do
          begin_attempt(ctx, nil, 0, nil)
        after
          Kogen.Harness.close(runtime)
          BaseWorkspace.remove(Process.delete(:kogen_base_workspace) || ctx.workspace)
        end

      # The latest context is kept, so the stop records what admission
      # reached (the boundary block) and removes what it created.
      {:error, ctx, reason} ->
        BaseWorkspace.remove(ctx.workspace)
        stop(ctx, reason)
    end
  end

  defp admission_step(step, {:ok, ctx}) do
    case step.(ctx) do
      {:ok, ctx} -> {:cont, {:ok, ctx}}
      {:error, reason} -> {:halt, {:error, ctx, reason}}
    end
  end

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
          Enum.map(@mix_redirection, &{&1, nil}),
      bindings: ctx.bindings,
      boundary:
        input
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(%{"mode" => boundary.mode, "sha256" => boundary.sha256})
    }
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
           Kogen.Harness.open_roles(ctx.config, @build_roles, ctx.control, launch(ctx)) do
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
                 ctx.plan,
                 %{control_root: ctx.control, candidate_root: ctx.root}
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

  # The local Verification Record and its history are archived and reset only
  # here, once per outer attempt, never between verification cycles.
  defp launch_attempt(ctx, session_id, number, reason) do
    with :ok <- inputs_unchanged(ctx),
         :ok <- Kogen.VerificationPolicy.preflight(ctx.catalog.ordered_targets, ctx.root),
         :ok <- invalidate_verification_record(ctx.control) do
      prompt = developer_prompt(ctx, reason)

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
    else
      {:error, reason} -> stop(ctx, reason)
    end
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

  defp developer_context(ctx), do: scrubbed_context(ctx, :developer)

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
          "developer_session_id" => turn.session_id,
          "developer_notes" => notes_record(turn.message),
          "developer_invocation" => invocation_evidence(turn.invocation_evidence)
        }
      )
    else
      verify_turn(
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
      :ok ->
        stop(
          ctx,
          "harness failure during Developer turn: #{inspect(reason)} #{role_label(ctx, :developer)}"
        )

      {:error, guard_reason} ->
        stop(ctx, guard_reason)
    end
  end

  # After every Developer turn this controller verifies the Candidate itself.
  # A failed cycle with retries left resumes the exact Developer session; it
  # never consumes the outer allowance and never reaches Jev or Review.
  defp verify_turn(ctx, session_id, number, notes, invocation) do
    with :ok <- post_developer_inputs_unchanged(ctx),
         {:ok, candidate_id} <- Kogen.Git.candidate_id(ctx.root),
         {:ok, execution, state} <-
           Verification.run_cycle(ctx.execution, session_id, candidate_id, cycle_env(ctx)) do
      ctx = %{ctx | execution: execution, workspace: execution.workspace || ctx.workspace}
      # The newest base workspace is removed when the Build ends.
      Process.put(:kogen_base_workspace, ctx.workspace)

      if state["terminal_state"] == "pending" do
        resume_after_failed_cycle(ctx, session_id, number, state, notes, invocation)
      else
        settle(ctx, session_id, number, notes, invocation, candidate_id)
      end
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp cycle_env(ctx) do
    %{
      root: ctx.root,
      control_root: ctx.control,
      catalog: ctx.catalog,
      plan: ctx.plan,
      scenarios: ctx.contract.scenarios,
      base_commit: ctx.base_commit,
      workspace: ctx.workspace
    }
  end

  defp resume_after_failed_cycle(ctx, session_id, number, state, notes, invocation) do
    cycle = List.last(state["cycles"])

    case record_attempt(ctx, %{
           "developer_session_id" => session_id,
           "developer_notes" => notes_record(notes),
           "developer_invocation" => invocation
         }) do
      {:ok, ctx} ->
        prompt = verification_failure_prompt(ctx, state, cycle)
        result = resume_developer(ctx, session_id, prompt)
        receive_developer(ctx, session_id, number, result)

      {:error, reason} ->
        stop(ctx, reason)
    end
  end

  # Names the failed target and its retained receipt and log paths, as
  # absolute control paths that open from the Candidate cwd. The controller's
  # context, state and history paths are never given out.
  defp verification_failure_prompt(ctx, state, cycle) do
    failure = cycle["failure"]
    retries = ctx.execution.context["verification_retries"]
    left = retries + 1 - state["failures_since_pass"]

    receipt =
      case Enum.find(cycle["receipts"], &(&1["target"] == failure["target"])) do
        nil ->
          "none (the cycle failed before `make #{failure["target"]}` produced a receipt)"

        _receipt ->
          Verification.receipt_path(ctx.execution, cycle["sequence"], failure["target"])
      end

    log =
      if is_binary(failure["log_path"]),
        do: Path.expand(failure["log_path"], ctx.control),
        else: failure["log_path"]

    target_line =
      case failure["kind"] do
        "target" -> "`make #{failure["target"]}` failed"
        "catalog" -> "the Candidate's verification-target catalog check failed"
        "proof" -> "the controller-run proof selectors of scenario `#{failure["target"]}` failed"
        kind -> "`#{failure["target"]}` failed (#{kind})"
      end

    """
    Controller verification failed after your turn (cycle #{cycle["sequence"]}, Candidate `#{cycle["candidate_id"]}`): #{target_line}.

    - Failed target: `#{failure["target"]}` (#{failure["kind"]})
    - Retained receipt: `#{receipt}`
    - Retained log: `#{log}` (sha256 #{failure["log_sha256"]})
    - Verification retries left after this one: #{max(left - 1, 0)} of #{retries}

    Read the log, fix the Candidate, and end your turn. Kogen's Build controller runs `check` and the selected targets again after your turn; do not run them yourself.

    Log tail:

    ```text
    #{String.slice(failure["output"] || "", -6_000, 6_000)}
    ```
    """
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
      if verification["terminal_state"] == "passed",
        do: settle_notes(ctx, candidate_id, session_id, number, notes, verification),
        else: stop(ctx, terminal_exhaustion_reason(ctx, verification))
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp settle_notes(ctx, candidate_id, session_id, number, notes, verification) do
    case read_notes(ctx, candidate_id, notes) do
      {:ok, ctx, jev} ->
        settle_outcome(ctx, candidate_id, session_id, number, notes, verification, jev)

      {:error, reason} ->
        stop(ctx, reason)
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
    cycle = List.last(ctx.execution.state["cycles"])
    proofs = List.wrap(cycle["proofs"])

    with {:ok, changes} <- candidate_changes(ctx.root, candidate_id),
         {:ok, ledger} <- verification_ledger(ctx, candidate_id, attempt, cycle),
         {base_suite, workspace} = base_suite(ctx, candidate_id),
         ctx = %{ctx | workspace: workspace || ctx.workspace},
         report =
           Report.build(%{
             contract: ctx.contract,
             attempt_token: ctx.token,
             candidate_id: candidate_id,
             open_findings: Tracking.open_findings(ctx.tracking),
             changes: changes,
             receipts: attempt["receipts"],
             proofs: proofs,
             labels: Map.new(ctx.plan.scenarios, &{&1["id"], &1["label"]}),
             ledger: ledger,
             base_suite: base_suite,
             jev: jev,
             existing?: &File.regular?(Path.join(ctx.root, &1))
           }),
         {:ok, references} <- snapshot_references(report, ctx),
         {:ok, ctx} <-
           record_attempt(ctx, %{
             "outcome" => "settled",
             "handoff" => report,
             "verification_ledger" => ledger,
             "base_suite" => base_suite,
             "developer_reference_snapshots" => references
           }) do
      Process.put(:kogen_base_workspace, ctx.workspace)
      review(%{ctx | references: references}, candidate_id, session_id, number)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

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
  defp settle_transport_failure(ctx, number, reason, evidence) do
    session_id = evidence[:session_id]

    case post_developer_inputs_unchanged(ctx) do
      :ok ->
        stop(
          ctx,
          "harness failure during Developer turn: #{inspect(reason)} #{role_label(ctx, :developer)}",
          %{
            "developer_session_id" => session_id,
            "developer_invocation" => invocation_evidence(evidence),
            "outer_attempt" => number
          }
        )

      {:error, guard_reason} ->
        stop(ctx, guard_reason, %{"developer_invocation" => invocation_evidence(evidence)})
    end
  end

  # The catalog is no longer byte-frozen: each cycle checks the Candidate's
  # catalog as data and a violation returns to the same Developer.
  defp post_developer_inputs_unchanged(ctx) do
    with :ok <- inputs_unchanged(ctx) do
      GuardedPaths.check(ctx.guarded_snapshot, ctx.intent.may_change_guarded_paths)
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
                 "file" => "state.json",
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

    target =
      get_in(cycle, ["failure", "target"]) ||
        (List.last(cycle["receipts"]) || %{})["target"] || "unknown"

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
        render_reviewer_prompt(ctx.intent, candidate_id, ctx.config, ctx.control) <>
          reviewer_notes_section(ctx) <> task_context(ctx, candidate_id, "reviewer")

      # The verdict schema is chosen per launch: `ledger` is required exactly
      # when this attempt's packet carries a nonempty ledger.
      context =
        ctx
        |> scrubbed_context(:reviewer)
        |> Kogen.Harness.with_ledger(ledger_paths(ctx))

      result =
        Kogen.Harness.launch_reviewer(
          prompt,
          ctx.config.reviewer.model,
          ctx.config.reviewer.effort,
          context
        )

      receive_review(ctx, candidate_id, session_id, number, result)
    else
      {:error, reason} -> stop(ctx, reason)
    end
  end

  defp ledger_paths(ctx), do: Ledger.paths(current_attempt(ctx)["verification_ledger"])

  # One immutable packet per attempt, written before launch. Its binding lives
  # in controller state and in the attempt, and every later input check
  # verifies it, so a rebuilt or edited packet stops the Build.
  defp write_review_packet(ctx, candidate_id, number) do
    input = %{
      record: ctx.tracking.record,
      record_path: Tracking.relative_path(ctx.tracking),
      record_bytes: ctx.tracking.bytes,
      candidate_id: candidate_id,
      open_findings: Enum.map(Tracking.open_findings(ctx.tracking), & &1["id"])
    }

    with {:ok, bytes} <- ReviewPacket.build(input),
         {:ok, binding} <-
           ReviewPacket.write(
             ctx.tracking.path,
             number,
             bytes,
             ctx.token,
             candidate_id,
             ctx.control
           ),
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
  defp review_packet_unchanged(%{"review_packet" => binding} = attempt, control) do
    if binding["attempt_token"] == attempt["attempt_token"] and
         binding["candidate_id"] == attempt["candidate_id"],
       do: ReviewPacket.verify(binding, control),
       else: {:error, "review packet is not bound to its attempt and Candidate"}
  end

  defp review_packet_unchanged(_attempt, _control), do: :ok

  defp receive_review(ctx, candidate_id, session_id, number, {:ok, verdict}) do
    binding = %{
      candidate_id: candidate_id,
      attempt_token: ctx.token,
      root: ctx.root,
      control: ctx.control,
      tracking_path: ctx.tracking.path
    }

    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         :ok <- fresh_reviewer(ctx, verdict.session_id, session_id),
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
        stop(ctx, "Reviewer failure: #{reason} #{role_label(ctx, :reviewer)}", %{
          "invalid_verdict" => verdict.response
        })
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
    stop(ctx, "Reviewer failure: #{inspect(error)} #{role_label(ctx, :reviewer)}", %{
      "invalid_verdict" => details
    })
  end

  defp receive_review(ctx, _candidate_id, _session_id, _number, {:error, reason}),
    do: stop(ctx, "Reviewer failure: #{inspect(reason)} #{role_label(ctx, :reviewer)}")

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

  # The record's `candidate` block is sealed as `published` before the
  # summary digest is written into the Complete package; a later refusal
  # replaces it with `retained` or `published-retained` and the commit.
  defp publish(ctx, candidate_id, session_id, verdict, number) do
    with :ok <- bound_inputs_unchanged(ctx, candidate_id, session_id),
         {:ok, ctx} <- record_attempt(ctx, %{"reference_snapshots" => ctx.references}),
         {:ok, ctx} <- record_candidate(ctx, "published", nil) do
      attempt = current_attempt(ctx)

      case accept(ctx, candidate_id, session_id, verdict, number, attempt_receipts(attempt)) do
        {:ok, commit} -> publish_to_control(ctx, commit)
        {:error, reason} -> stop(ctx, reason)
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

    case Workspace.fast_forward(candidate, commit) do
      :ok ->
        File.rm_rf(Path.join([ctx.control, @approved_base, ctx.slug]))

        case Workspace.remove_published(candidate) do
          :ok -> :ok
          {:error, output} -> cleanup_refused(ctx, commit, output)
        end

      {:refused, reason, current} ->
        refuse_publication(ctx, commit, reason, current)

      {:error, reason} ->
        current = Workspace.branch_commit(ctx.control, candidate.admitted_branch)
        refuse_publication(ctx, commit, reason, current)
    end
  end

  # The admitted branch stays published; the Candidate is kept for the
  # Shaper. The record version the Complete summary binds is retained as a
  # sidecar before the disposition changes.
  defp cleanup_refused(ctx, commit, output) do
    candidate = ctx.candidate
    Tracking.retain_record_version(ctx.tracking, ctx.tracking.bytes)
    Workspace.update_status(candidate, "published: cleanup refused: #{output}", commit)

    suffix =
      case record_candidate(ctx, "published-retained", commit) do
        {:ok, _ctx} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    IO.puts(
      :stderr,
      "warning: published #{commit} on #{candidate.admitted_branch}, but the Candidate worktree was not removed: #{output}. " <>
        "Worktree #{candidate.path}, branch #{candidate.branch}; tracking record: #{ctx.tracking.path}#{suffix}. " <>
        "Remove it with `mix kogen.candidates.remove #{candidate.build_id}`."
    )

    :ok
  end

  defp refuse_publication(ctx, commit, reason, current) do
    candidate = ctx.candidate

    suffix =
      case record_candidate(ctx, "retained", commit) do
        {:ok, _ctx} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    Workspace.update_status(candidate, "accepted-unpublished: #{reason}", commit)

    {:error,
     "Accepted Candidate not published: #{reason}. Admitted #{candidate.admitted_branch} at #{candidate.admitted_commit}; current #{current || "(missing)"}. " <>
       "#{candidate.admitted_branch}, the control index and working tree and its Approved package are unchanged. " <>
       "Worktree #{candidate.path}, branch #{candidate.branch}, Candidate commit #{commit}; tracking record: #{ctx.tracking.path}#{suffix}. " <>
       "Fast-forward #{candidate.admitted_branch} yourself after tidying the control checkout, or discard it with " <>
       "`mix kogen.candidates.remove #{candidate.build_id} --discard-accepted`."}
  end

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
         :ok <- references_unchanged(ctx.references, ctx),
         :ok <- Tracking.verify_record_versions(ctx.tracking),
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

  # Every stop keeps the Candidate worktree, branch and harness home exactly
  # as they are, marks the owner record `stopped: <category>` and names the
  # Candidate next to the tracking record.
  defp stop(ctx, reason, details \\ %{}) do
    changes = Map.merge(details, %{"status" => "failed", "failure" => reason})

    result =
      case ctx.tracking.record["attempts"] do
        [] ->
          record_candidate(ctx, "retained", nil)

        _attempts ->
          with {:ok, ctx} <- record_attempt(ctx, changes),
               do: record_candidate(ctx, "retained", nil)
      end

    suffix =
      case result do
        {:ok, _ctx} -> ""
        {:error, error} -> "; tracking persistence/integrity failure: #{error}"
      end

    ids = Enum.map_join(ctx.contract.scenarios, ", ", & &1["id"])

    {:error,
     "#{reason}#{suffix}; unresolved scenarios: #{ids}; tracking record: #{ctx.tracking.path}" <>
       retained(ctx, reason)}
  end

  defp retained(%{candidate: nil}, _reason), do: ""

  defp retained(ctx, reason) do
    Workspace.update_status(ctx.candidate, "stopped: #{stop_category(reason)}")
    "; " <> Workspace.retained_description(ctx.candidate)
  end

  @stop_categories [
    {"verification retries exhausted", "verification-exhausted"},
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
    render_developer_prompt(ctx.intent, ctx.contract.text, ctx.targets, ctx.config, roots(ctx)) <>
      task_context(ctx, nil, "developer")
  end

  defp developer_prompt(ctx, reason) do
    render_developer_prompt(ctx.intent, ctx.contract.text, ctx.targets, ctx.config, roots(ctx)) <>
      "\n\n" <> resume_feedback(ctx, reason) <> task_context(ctx, nil, "developer")
  end

  defp roots(ctx), do: %{control: ctx.control, candidate: ctx.root}

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
  @packet_statement "Start from the review packet: it is your evidence source, bound to this attempt and Candidate. A cut or left-out item carries its digest and a record locator. The full tracking record is an audit locator only; never dump it whole. The packet never replaces inspecting the Candidate: read any Candidate file and run read-only commands."
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
      Tracking.retain_record_version(tracking, tracking.bytes)
    else
      with {:ok, bytes} <- File.read(reference_path(path, ctx)) do
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
         {:ok, head} <- Kogen.Git.commit_staged(ctx.intent.title, trailers, root) do
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
    readiness =
      case VerificationPlan.load(roots.control) do
        {:ok, catalog} ->
          # Rendering remains fail-closed in the real Build, which already
          # validated the same Approved proof data.
          case Contract.load(
                 Path.join([roots.control, @approved_base, intent.slug]),
                 roots.control
               ) do
            {:ok, contract} ->
              case VerificationPlan.build(
                     contract.scenarios,
                     intent.may_change_guarded_paths,
                     catalog,
                     roots.control,
                     added: added_targets(intent)
                   ) do
                {:ok, plan} ->
                  changed =
                    case Kogen.Git.changed_paths(roots.candidate) do
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
      "{{execution_policy}}",
      execution_policy(config, "developer", roots.control)
    )
  end

  # `Kogen.ExecutionPolicy` reads its maintained policy text relative to the
  # process working directory; it is a control-side engine asset, so it is
  # rendered with control as the working directory, named explicitly.
  defp execution_policy(config, role, control),
    do: File.cd!(control, fn -> Kogen.ExecutionPolicy.render(config, role) end)

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
