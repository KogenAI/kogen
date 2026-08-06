defmodule Mix.Tasks.Codegen.Loop do
  @shortdoc "Runs the deterministic orchestration loop for one pitch."

  @moduledoc """
  `mix codegen.loop --harness=claude_code --stack=<phoenix|static> --cwd=<dir> [--fallback-model=<m>] [--max-budget-usd=<n>] [--effort=<e>] [--commit-subject=<text>] <pitch>`

  Execs from the build-mode `dispatch.sh` path in place of a single
  self-orchestrating agent session. Runs `CodegenTestHarness.OrchestrationLoop.run/1`
  and exits:

  - `0` — cycle reached COMMITTED with a clear gate
  - `4` — COMMITTED and RETIRED (the pitch's work landed and left ready/ or
    building/ for shipped/, unconditionally), but the working tree was
    dirty at ship time — a ship-with-warning, not a failure. See
    `@dirty_tree_exit_code` and `warn_dirty_after_retire/1`.
  - non-zero, reason on stderr — any other failure (crash loud; no silent
    success)

  ## Flags

  - `--harness` — required, `claude_code`
  - `--stack` — required, `phoenix` | `static`
  - `--cwd` — required, project directory the loop operates in
  - `--fallback-model` — optional. Prepends `<m>` as rung 0 of EVERY role's
    `fallback:` chain for this run only (a one-build override of
    `templates/generator/config.yaml`, threaded from `codegen-build
    --fallback-model=<m>` via `CODEGEN_BUILD_FALLBACK_MODEL`). Absent →
    every role's chain is exactly what `config.yaml` declares, unchanged.
  - `--max-budget-usd` — optional. Once accumulated spend (summed across every
    role invocation, including gate retries) reaches this many USD, the loop
    aborts BETWEEN role invocations (the in-flight role always completes —
    its cost is already committed to the API). Threaded from `codegen-build
    --max-budget-usd=<n>` via `CODEGEN_BUILD_MAX_BUDGET_USD`. Absent → no cap,
    exactly today's behavior.
  - `--effort` — optional, one of `off|low|medium|high|xhigh|max`. Replaces
    every non-fixed-campaign role's configured effort for this run only (a
    one-build override of `templates/generator/config.yaml`, threaded from
    `codegen-build --effort=<e>` via `CODEGEN_BUILD_EFFORT`). Absent → every
    role's effort is exactly what `config.yaml` declares, unchanged. A fixed
    campaign binding (benchmark harness) still wins over this override for
    its own pinned role.
  - `--commit-subject` — the explicit substitute for a pitch's own
    `commit_subject:` frontmatter field, threaded from `codegen-build
    --commit-subject=<text>` via `CODEGEN_BUILD_COMMIT_SUBJECT`. Resolution
    order is explicit flag -> frontmatter -> refuse (fail-closed, never a
    silent default). REQUIRED for a literal-prompt build (no frontmatter to
    fall back to); optional for a pitch build that already carries
    `commit_subject:` — and the escape hatch for a pitch in a repo with no
    shape workflow at all. Validated via `codegen-commit --check-subject`
    before ANY role is invoked or spend occurs — see pitch "committing is
    deterministic, not a model call".
  - `<pitch>` — required positional arg, the prompt/pitch text (or `@<path>`
    to read it from a file, matching `codegen-call`'s `@<path>` convention)
  """

  use Mix.Task

  alias CodegenTestHarness.BuildSignalHandler
  alias CodegenTestHarness.InfraAbort
  alias CodegenTestHarness.InterruptedCycleRecovery
  alias CodegenTestHarness.LoopGate
  alias CodegenTestHarness.LoopQueue
  alias CodegenTestHarness.OrchestrationLoop

  # Distinct exit code for an infra abort (a fault no developer edit could
  # fix — see `CodegenTestHarness.InfraAbort`), separate from `1`
  # (deterministic cycle failure) and `2` (usage/flag error). This is the
  # signal `LoopQueueDrain` needs to tell "the box is broken" apart from
  # "this pitch's diff didn't pass" — both would otherwise be an
  # indistinguishable non-zero exit.
  @infra_abort_exit_code 3

  # Distinct exit code for "the pitch's work landed AND was retired, but
  # the working tree was dirty at ship time" (see `warn_dirty_after_retire/1`).
  # This is NOT a failure — the commit landed, the pitch left ready/ and is
  # in shipped/ — but it is not a silent success either, since something
  # (stray render artifacts, a leftover edit) is sitting uncommitted. Distinct
  # from `1` (deterministic cycle failure, pitch NOT retired) so
  # `LoopQueueDrain` can count this as a ship-with-warning rather than
  # requeue a pitch whose work is already on develop (see
  # codegen/pitches/shipped/a-landed-pitch-cannot-be-handed-out-again.md).
  @dirty_tree_exit_code 4

  @impl Mix.Task
  def run(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          harness: :string,
          stack: :string,
          cwd: :string,
          fallback_model: :string,
          max_budget_usd: :float,
          effort: :string,
          commit_subject: :string
        ]
      )

    if invalid != [] do
      Mix.shell().error("codegen.loop: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    harness = Keyword.get(opts, :harness) || missing_flag!("--harness")
    stack = Keyword.get(opts, :stack) || missing_flag!("--stack")
    cwd = Keyword.get(opts, :cwd) || missing_flag!("--cwd")
    # Optional: absent -> nil -> OrchestrationLoop.run/1 does not override
    # any role's fallback chain, exactly today's behavior.
    fallback_model = Keyword.get(opts, :fallback_model)
    # Optional: absent -> nil -> OrchestrationLoop.run/1 enforces no spend
    # cap, exactly today's behavior.
    max_budget_usd = Keyword.get(opts, :max_budget_usd)
    # Optional: absent -> nil -> OrchestrationLoop.run/1 applies no
    # build-wide effort override, exactly today's behavior.
    effort_override = Keyword.get(opts, :effort)
    # Optional: the explicit substitute for a pitch's own commit_subject:
    # frontmatter — required for a literal prompt, and the escape hatch for
    # a pitch in a repo with no shape workflow (no frontmatter producer at
    # all). Resolution order is explicit flag -> frontmatter -> refuse,
    # never a silent default (see pitch "committing is deterministic, not
    # a model call").
    commit_subject_flag = Keyword.get(opts, :commit_subject)

    # Move 2: install the SIGTERM handler for the solo path (SIGINT cannot
    # be caught at the BEAM level — see BuildSignalHandler moduledoc; the
    # shared harnesses/shared/loop-signal-bridge.sh helper, sourced by
    # dispatch.sh, forwards SIGINT as a group SIGTERM to this process group).
    # Unlike the queue drain (which tracks a Port os_pid), this path's heavy
    # subprocess runs via synchronous `System.cmd/3` with no exposed os_pid
    # — the reap here targets THIS process's own OS descendant subtree
    # (`LoopQueueDrain.reap_own_descendants/0`) rather than a single tracked
    # child.
    lock_path = Path.join([cwd, "codegen", "gate-pending", "queue.lock"])

    :ok =
      BuildSignalHandler.install(lock_path,
        reap_fn: &CodegenTestHarness.LoopQueueDrain.reap_own_descendants/0
      )

    pitch_arg =
      case positional do
        [pitch_arg | _] -> pitch_arg
        [] -> missing_flag!("<pitch>")
      end

    requested_source = resolve_pitch_source(pitch_arg, cwd)
    requested_slug = source_slug(requested_source)

    result =
      OrchestrationLoop.with_startup_guard(
        [cwd: cwd, harness: harness, stack: stack],
        fn ->
          roles = OrchestrationLoop.role_sequence(stack)

          route_reconcile_result(
            InterruptedCycleRecovery.reconcile(cwd: cwd, roles: roles),
            requested_slug,
            fn ->
              run_claimed_cycle(
                requested_source,
                pitch_arg,
                cwd,
                harness,
                stack,
                fallback_model,
                max_budget_usd,
                effort_override,
                commit_subject_flag
              )
            end
          )
        end
      )

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("codegen.loop: FAILED — #{reason}")
        exit({:shutdown, 1})
    end
  end

  # Routes an `InterruptedCycleRecovery.reconcile/1` result — pulled out of
  # `run/1` as its own function so the decision is directly testable without
  # exercising OptionParser/BuildSignalHandler/git plumbing.
  #
  # `reconcile/1` parks/cleans a STRANDED `building/` claim at startup (a
  # DIFFERENT slug than this invocation's target, almost always): its
  # result is now CLEANUP/INFORMATION ONLY, never a selection veto (see
  # pitch "restarted builds resume owned work" — the historical
  # `{:error, "interrupted pitch X must resume before Y"}` arm forced
  # priority onto a recovered slug regardless of what the operator actually
  # requested; dormant recovery must never reorder selection). Every
  # `{:ok, _}` shape — including `{:resume, _}` for a DIFFERENT slug than
  # requested — falls through to `run_fn.()` so the operator's own
  # requested slug always proceeds. Only a genuine reconcile ERROR (a
  # malformed/ambiguous journal, an unresolvable git state) still refuses.
  @doc false
  @spec route_reconcile_result(
          {:ok, CodegenTestHarness.InterruptedCycleRecovery.recovery()} | {:error, String.t()},
          String.t() | nil,
          (-> :ok | {:error, String.t()})
        ) :: :ok | {:error, String.t()}
  def route_reconcile_result({:ok, _recovery}, _requested_slug, run_fn), do: run_fn.()
  def route_reconcile_result({:error, reason}, _requested_slug, _run_fn), do: {:error, reason}

  defp source_slug({:file, abs}), do: Path.basename(abs, ".md")
  defp source_slug(:literal), do: nil

  # The pitch's own `scope:` frontmatter list — the deterministic deliverable
  # file list the build is graded against. `resolve_pitch/2` pipes
  # the file through `LoopQueue.strip_frontmatter/1` and throws the
  # frontmatter away, so the field is re-read here from the CLAIMED path and
  # threaded into the loop as `:pitch_scope`. Two consumers, one parse: the
  # loop's own `{"ev":"files_to_touch","role":"loop",...}` event (the
  # developer's `context/*.md` Read grant) and the `## Declared Scope` block
  # `build_prompt/2` threads to the developer and the reviewer.
  #
  # Fail-closed for a queue-driven build. `scope:` is MANDATORY for every
  # pitch promoted to `ready/` (context/pitch-writing-guide.md) and already
  # gate-checked by `make pitch-scope-parity`, so a missing one is a repo
  # fault, not a runtime condition. Degrading silently would leave the
  # reviewer's mechanical coverage check with nothing to check — the exact
  # "absent -> vacuous pass" hole `context/rules-roles.md` § Producer-ABSENT
  # warns can let a sliced, born-dead build ship undetected. Ad-hoc literal
  # pitches (and a `--pitch=@<path>` pointing outside `codegen/pitches/`)
  # carry no frontmatter contract at all, so they stay permissive (nil) and
  # the reviewer reports the mechanical half N/A.
  @doc false
  @spec resolve_pitch_scope!({:file, String.t()} | :literal, String.t()) :: [String.t()] | nil
  def resolve_pitch_scope!(:literal, _slug), do: nil

  def resolve_pitch_scope!({:file, abs}, slug) do
    case LoopQueue.parse_scope(slug, abs) do
      {:ok, nil} ->
        if queue_pitch_path?(abs) do
          LoopGate.infra_abort!(
            "pitch-scope-preflight",
            "#{slug} declares no scope: frontmatter field — a queued pitch must name the " <>
              "files it delivers, and nothing downstream can reconstruct that list. Add " <>
              "`scope: [...]` to the pitch (see context/pitch-writing-guide.md; " <>
              "`make pitch-scope-parity` checks it) and re-run."
          )
        else
          nil
        end

      {:ok, files} ->
        files
    end
  end

  @spec queue_pitch_path?(String.t()) :: boolean()
  defp queue_pitch_path?(abs) do
    abs
    |> Path.expand()
    |> Path.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&match?(["codegen", "pitches"], &1))
  end

  # Resolves the sealed commit subject this cycle will pass to the
  # deterministic `codegen-commit` step. Resolution order is explicit flag
  # -> pitch frontmatter -> refuse (fail-closed, never a silent default —
  # see pitch "committing is deterministic, not a model call").
  #
  # Runs BEFORE `claim_pitch!/2` (called from `run_claimed_cycle/9`, not
  # inlined into `claim_pitch!/2`'s own body — that function's arity-2
  # contract has a large pre-existing test surface, and running this check
  # strictly before the call achieves the identical fail-closed-before-spend
  # guarantee without touching it) so a missing/invalid subject is refused
  # before any role invocation, model spend, or ready/->building/ rename —
  # the same fail-closed posture `verify_handoff_receipt_before_claim!/1`
  # already applies to `handoffs:` from inside `claim_pitch!/2`.
  #
  # A `--commit-subject` flag ALWAYS wins when given, even for a pitch that
  # also carries `commit_subject:` frontmatter — the flag is the explicit,
  # in-the-moment override; the frontmatter is the pitch's own default.
  # Mechanical validity is checked via `codegen-commit --check-subject`,
  # the single implementation shared with `/ready` and
  # `pitch-format-validator.sh` — the rule is defined once, not duplicated
  # in Elixir.
  @spec resolve_commit_subject!({:file, String.t()} | :literal, String.t() | nil) :: String.t()
  defp resolve_commit_subject!(source, commit_subject_flag) do
    frontmatter_subject =
      case source do
        :literal ->
          nil

        {:file, abs} ->
          slug = source_slug(source) || Path.basename(abs, ".md")
          {:ok, subject} = LoopQueue.parse_commit_subject(slug, abs)
          subject
      end

    subject = commit_subject_flag || frontmatter_subject

    cond do
      is_nil(subject) or subject == "" ->
        Mix.shell().error(
          "codegen.loop: no commit subject available — the pitch declares no " <>
            "commit_subject: frontmatter field and no --commit-subject flag was " <>
            "given. A literal prompt ALWAYS requires --commit-subject=<text>; a " <>
            "pitch build requires either commit_subject: in frontmatter or the " <>
            "same flag (see pitch \"committing is deterministic, not a model call\")."
        )

        exit({:shutdown, 2})

      not check_subject_valid?(subject) ->
        Mix.shell().error(
          "codegen.loop: commit subject #{inspect(subject)} failed codegen-commit " <>
            "--check-subject validation — fix it in frontmatter or the --commit-subject " <>
            "flag and re-run."
        )

        exit({:shutdown, 2})

      true ->
        subject
    end
  end

  @codegen_commit_bin Path.expand("../../../../codegen-commit", __DIR__)

  @spec check_subject_valid?(String.t()) :: boolean()
  defp check_subject_valid?(subject) do
    case System.cmd(@codegen_commit_bin, ["--check-subject", subject], stderr_to_stdout: true) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end

  defp run_claimed_cycle(
         source,
         pitch_arg,
         cwd,
         harness,
         stack,
         fallback_model,
         max_budget_usd,
         effort_override,
         commit_subject_flag
       ) do
    pitch = resolve_pitch(pitch_arg, cwd)
    commit_subject = resolve_commit_subject!(source, commit_subject_flag)
    source = claim_pitch!(source, cwd)
    slug = source_slug(source) || "adhoc"
    pitch_scope = resolve_pitch_scope!(source, slug)

    if source != :literal do
      InterruptedCycleRecovery.complete_resume_claim!(cwd, slug)
    end

    # Same-slug materialization: selecting a slug that already carries an
    # active recovery dossier IS the explicit adoption action (no new CLI
    # flag — see pitch "restarted builds resume owned work"). A dossier for
    # a DIFFERENT slug (or none at all) is untouched — recovery stays
    # dormant, this cycle starts fresh. `recovery_mode`/`recovery_role`
    # thread into `OrchestrationLoop.run/1` so the preflight-clean-tree
    # guard is bypassed for the recovered dirty bytes and the cycle starts
    # at the earliest role whose prior output remains trustworthy.
    {recovery_mode, recovery_role} = materialize_recovery(source, cwd, slug, stack)

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    cycle_id = "#{stamp}_#{slug}"
    head_before = git_head(cwd)

    result =
      run_loop_catching_infra_abort(fn ->
        OrchestrationLoop.run(
          harness: harness,
          stack: stack,
          cwd: cwd,
          pitch: pitch,
          pitch_scope: pitch_scope,
          cycle_id: cycle_id,
          slug: slug,
          stamp: stamp,
          build_lock_held: true,
          fallback_model_override: fallback_model,
          max_budget_usd: max_budget_usd,
          effort_override: effort_override,
          recovery_mode: recovery_mode,
          recovery_role: recovery_role,
          commit_subject: commit_subject
        )
      end)

    emit_loop_telemetry(result)

    case result do
      :ok ->
        case verify_commit_landed(head_before, cwd) do
          {:ok, after_sha} ->
            Mix.shell().info("codegen.loop: COMMITTED, gate clear")
            InterruptedCycleRecovery.complete_transaction!(cwd, slug)
            maybe_ship_pitch(source, cwd, before_sha(head_before), after_sha)
            write_build_result!(cwd, slug, after_sha)

          {:error, reason} ->
            park_and_restore_claim(source, pitch, cwd, slug, reason)
            {:error, reason}
        end

      {:error, reason} ->
        park_and_restore_claim(source, pitch, cwd, slug, reason)
        {:error, reason}
    end
  end

  # Resolves `slug`'s active recovery dossier (if any) and, when found,
  # materializes it onto the current tree BEFORE the loop runs. Returns
  # `{nil, nil}` (no recovery, byte-for-byte today's behavior) when there is
  # no active dossier for this slug, or when the dossier belongs to a
  # different slug/was never selected this invocation. A materialization
  # `{:error, reason}` is fatal — the claimed pitch's own recovered bytes
  # could not be safely restored, so the cycle must not proceed pretending
  # nothing happened.
  @doc false
  @spec materialize_recovery({:file, String.t()} | :literal, String.t(), String.t(), String.t()) ::
          {CodegenTestHarness.InterruptedCycleRecovery.disposition() | nil, String.t() | nil}
  def materialize_recovery(:literal, _cwd, _slug, _stack), do: {nil, nil}

  def materialize_recovery({:file, _abs}, cwd, slug, stack) do
    case InterruptedCycleRecovery.materialize(cwd, slug) do
      {:ok, :none} ->
        {nil, nil}

      {:ok, {disposition, dossier}} ->
        roles = OrchestrationLoop.role_sequence(stack)

        role =
          OrchestrationLoop.resume_role_for_recovery(disposition, dossier["cycle_state"], roles)

        Mix.shell().info(
          "codegen.loop: recovered #{slug} (#{disposition}) — resuming at " <>
            OrchestrationLoop.display_resume_role(role)
        )
        {disposition, role}

      {:error, reason} ->
        Mix.shell().error("codegen.loop: FAILED — #{reason}")
        exit({:shutdown, 1})
    end
  end

  # Parks whatever the cycle left dirty on a CONTROLLED direct failure —
  # BEFORE restoring the claim. `restore_claim/2` always runs regardless of
  # whether parking itself succeeded: a park failure is non-blocking
  # observability on the pitch's own posture (see pitch "restarted builds
  # resume owned work" defect #6) and must never strand the pitch outside
  # `ready/`. A park failure is logged loud but does not change the
  # cycle's own `{:error, reason}` outcome (already decided by the caller).
  @doc false
  @spec park_and_restore_claim(
          {:file, String.t()} | :literal,
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok
  def park_and_restore_claim(:literal, _pitch, cwd, _slug, _reason),
    do: restore_claim(:literal, cwd)

  def park_and_restore_claim({:file, abs} = source, _pitch, cwd, slug, reason) do
    case InterruptedCycleRecovery.park_failure(
           cwd: cwd,
           pitch_path: abs,
           slug: slug,
           namespace: "recovery/interrupted",
           cause: reason
         ) do
      {:ok, _dossier} ->
        :ok

      {:error, park_reason} ->
        Mix.shell().error("codegen.loop: park_failure could not preserve #{slug}: #{park_reason}")
        :ok
    end

    restore_claim(source, cwd)
  end

  # Claims a `ready/<slug>.md` pitch by an atomic same-filesystem rename into
  # `building/<slug>.md`, BEFORE the loop runs — the moment of possession.
  # A `File.rename/2` race loser gets `{:error, :enoent}` (the source is
  # already gone) and refuses loud rather than silently proceeding to build
  # a pitch someone else is already building. Any other rename error
  # propagates uncaught (a genuine anomaly, never swallowed).
  #
  # Deliberately NOT called from `run_loop_catching_infra_abort/1`'s rescue
  # arm — an infra abort must leave the pitch in `building/`, mirroring
  # `LoopQueueDrain.handle_infra_abort/4`'s existing "pitch remains
  # untouched" posture (the box is broken; nothing about the pitch was
  # wrong).
  @doc false
  @spec claim_pitch!({:file, String.t()} | :literal, String.t()) ::
          {:file, String.t()} | :literal
  def claim_pitch!(:literal, _cwd), do: :literal

  def claim_pitch!({:file, abs}, cwd) do
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    building_dir = Path.join([cwd, "codegen", "pitches", "building"])
    name = Path.basename(abs)
    src_in_ready = Path.join(ready_dir, name)

    if Path.expand(abs) == Path.expand(src_in_ready) do
      verify_handoff_receipt_before_claim!(abs)
      File.mkdir_p!(building_dir)
      dst = Path.join(building_dir, name)

      case File.rename(src_in_ready, dst) do
        :ok ->
          {:file, dst}

        {:error, :enoent} ->
          slug = Path.basename(abs, ".md")
          Mix.shell().error("codegen.loop: pitch already claimed (building/) — #{slug}")
          exit({:shutdown, 2})

        {:error, reason} ->
          raise "codegen.loop: claim_pitch! failed to rename #{src_in_ready} -> #{dst}: " <>
                  "#{inspect(reason)}"
      end
    else
      {:file, abs}
    end
  end

  # Pre-spend receipt backstop — verifies a ready/<slug>.md pitch's own
  # handoff_receipt: (if any) BEFORE the possession rename below, so an
  # invalid/stale/orphan receipt is refused before any role invocation or
  # model spend. A pitch with no handoffs: and no handoff_receipt: is a
  # no-op pass (the common case — most pitches carry no cross-pitch
  # deferral). A pitch with handoffs: but a missing/malformed/mismatched
  # receipt refuses loud, naming the slug, and leaves the file untouched in
  # ready/ (this runs strictly before File.rename below).
  @spec verify_handoff_receipt_before_claim!(String.t()) :: :ok
  defp verify_handoff_receipt_before_claim!(abs) do
    slug = Path.basename(abs, ".md")

    case LoopQueue.parse_handoffs(slug, abs) do
      {:ok, nil} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, records} ->
        content = File.read!(abs)
        receipt = LoopQueue.frontmatter_block(content) |> extract_receipt()

        expected = LoopQueue.handoff_receipt(slug, records)

        if receipt == expected do
          :ok
        else
          Mix.shell().error(
            "codegen.loop: pitch #{inspect(slug)} has handoffs: but no valid " <>
              "handoff_receipt: (absent, stale, or malformed) — refusing to claim"
          )

          exit({:shutdown, 2})
        end
    end
  end

  @spec extract_receipt(String.t() | nil) :: String.t() | nil
  defp extract_receipt(nil), do: nil

  defp extract_receipt(block) do
    case Regex.run(~r/^handoff_receipt:\s*(\S+)\s*$/m, block) do
      [_, value] -> value
      nil -> nil
    end
  end

  # Restores a claimed pitch from building/ back to ready/ on a diff-failure
  # exit — the pitch's work did NOT land, so it must remain dispatchable to
  # the next builder. A no-op for a source that was never claimed (:literal,
  # or a file outside building/).
  @doc false
  @spec restore_claim({:file, String.t()} | :literal, String.t()) :: :ok
  def restore_claim(:literal, _cwd), do: :ok

  def restore_claim({:file, abs}, cwd) do
    building_dir = Path.join([cwd, "codegen", "pitches", "building"])
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    name = Path.basename(abs)
    src_in_building = Path.join(building_dir, name)

    if Path.expand(abs) == Path.expand(src_in_building) and File.exists?(src_in_building) do
      File.mkdir_p!(ready_dir)
      File.rename!(src_in_building, Path.join(ready_dir, name))
      :ok
    else
      :ok
    end
  end

  # Runs `run_fn` and converts a raised `CodegenTestHarness.InfraAbort` into
  # process exit code `@infra_abort_exit_code` (3) — the signal
  # `LoopQueueDrain` needs to tell "the box is broken" apart from "this
  # pitch's diff didn't pass" (see module doc). Extracted as its own
  # function (rather than inlined in `run/1`) so it is directly testable
  # without exercising OptionParser/git/telemetry plumbing: a test can pass
  # a `run_fn` that raises `InfraAbort` and assert the resulting exit
  # without needing a real cwd/pitch/harness.
  @doc false
  @spec run_loop_catching_infra_abort((-> :ok | {:error, String.t()})) ::
          :ok | {:error, String.t()}
  def run_loop_catching_infra_abort(run_fn) do
    run_fn.()
  rescue
    e in InfraAbort ->
      Mix.shell().error("codegen.loop: #{e.message}")
      exit({:shutdown, @infra_abort_exit_code})
  end

  @doc false
  @spec write_build_result!(String.t(), String.t(), String.t() | nil) :: :ok
  def write_build_result!(cwd, slug, head) do
    case System.get_env("CODEGEN_BUILD_INVOCATION_ID") do
      invocation_id when is_binary(invocation_id) and invocation_id != "" ->
        path = Path.join([cwd, "codegen", "gate-pending", "build-result.json"])
        File.mkdir_p!(Path.dirname(path))

        temporary =
          Path.join(Path.dirname(path), ".build-result.#{System.unique_integer([:positive])}")

        payload =
          Jason.encode!(%{
            "head" => head,
            "invocation_id" => invocation_id,
            "slug" => slug,
            "status" => "success",
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        File.write!(temporary, payload)
        File.rename!(temporary, path)
        :ok

      _ ->
        :ok
    end
  end

  @doc false
  def emit_loop_telemetry(result) do
    t = OrchestrationLoop.get_telemetry()

    subtype = if result == :ok, do: "success", else: "error"

    per_role =
      Map.new(t.per_role, fn {role, entries} ->
        summed =
          Enum.reduce(
            entries,
            %{
              cost_usd: 0.0,
              input_tokens: 0,
              output_tokens: 0,
              num_turns: 0,
              cache_read_tokens: 0,
              cache_creation_tokens: 0
            },
            fn e, acc ->
              %{
                cost_usd: acc.cost_usd + e.cost_usd,
                input_tokens: acc.input_tokens + e.input_tokens,
                output_tokens: acc.output_tokens + e.output_tokens,
                num_turns: acc.num_turns + e.num_turns,
                cache_read_tokens: acc.cache_read_tokens + e.cache_read_tokens,
                cache_creation_tokens: acc.cache_creation_tokens + e.cache_creation_tokens
              }
            end
          )

        # Additive: each entry's `dispatch` (harness/model/effort actually
        # requested for that invocation — see
        # `OrchestrationLoop.accumulate_telemetry/3`) is projected here as an
        # ORDERED list, one per call, in the order they were made. Every
        # existing key above (cost_usd, tokens, calls, ...) is untouched —
        # this is a new key on the same map, never a replacement.
        dispatches = Enum.map(entries, & &1.dispatch)

        {role, summed |> Map.put(:calls, length(entries)) |> Map.put(:dispatches, dispatches)}
      end)

    line =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => subtype,
        "engine" => "elixir_loop",
        "num_turns" => t.num_turns,
        "total_cost_usd" => t.cost_usd,
        "terminal_reason" => if(result == :ok, do: "loop_committed", else: "loop_failed"),
        "role_calls" => t.role_calls,
        "usage" => %{
          "input_tokens" => t.input_tokens,
          "output_tokens" => t.output_tokens,
          "cache_read_input_tokens" => t.cache_read_tokens,
          "cache_creation_input_tokens" => t.cache_creation_tokens
        },
        "per_role" => per_role
      })

    IO.puts(line)
  end

  @doc false
  @spec resolve_pitch(String.t(), String.t()) :: String.t()
  def resolve_pitch("@" <> path, cwd) do
    abs = Path.expand(path, cwd)

    unless File.exists?(abs) do
      Mix.shell().error("codegen.loop: pitch file not found at #{abs}")
      exit({:shutdown, 2})
    end

    abs
    |> File.read!()
    |> LoopQueue.strip_frontmatter()
  end

  def resolve_pitch(literal, cwd) do
    abs = Path.expand(literal, cwd)

    if File.exists?(abs) do
      abs
      |> File.read!()
      |> LoopQueue.strip_frontmatter()
    else
      literal
    end
  end

  @doc false
  @spec resolve_pitch_source(String.t(), String.t()) :: {:file, String.t()} | :literal
  def resolve_pitch_source("@" <> path, cwd) do
    abs = Path.expand(path, cwd)
    if File.exists?(abs), do: {:file, abs}, else: :literal
  end

  def resolve_pitch_source(literal, cwd) do
    abs = Path.expand(literal, cwd)
    if File.exists?(abs), do: {:file, abs}, else: :literal
  end

  # Extracts the sha string from git_head/1's {:ok, sha} | :unborn shape for
  # threading into maybe_ship_pitch/4 — :unborn (non-git cwd) becomes nil,
  # which is record_ship/4's own fail-open carve-out.
  @spec before_sha({:ok, String.t()} | :unborn) :: String.t() | nil
  defp before_sha({:ok, sha}), do: sha
  defp before_sha(:unborn), do: nil

  @doc false
  @spec maybe_ship_pitch(
          {:file, String.t()} | :literal,
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  def maybe_ship_pitch(source, cwd, before_sha \\ nil, after_sha \\ nil)

  def maybe_ship_pitch(:literal, _cwd, _before_sha, _after_sha), do: :ok

  def maybe_ship_pitch({:file, abs}, cwd, before_sha, after_sha) do
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    building_dir = Path.join([cwd, "codegen", "pitches", "building"])
    name = Path.basename(abs)
    src_in_ready = Path.join(ready_dir, name)
    src_in_building = Path.join(building_dir, name)

    # A claimed pitch's source is building/<name> (the normal path, post
    # claim_pitch!); a still-ready/<name> source is the legacy/no-claim
    # shape (e.g. a test driving maybe_ship_pitch/4 directly). Either is a
    # valid ship source.
    src =
      cond do
        Path.expand(abs) == Path.expand(src_in_building) -> src_in_building
        Path.expand(abs) == Path.expand(src_in_ready) -> src_in_ready
        true -> nil
      end

    if src do
      shipped_dir = Path.join([cwd, "codegen", "pitches", "shipped"])
      slug = Path.basename(abs, ".md")

      ship_ready_pitch(
        src,
        Path.join(shipped_dir, name),
        cwd,
        slug,
        before_sha,
        after_sha
      )
    else
      :ok
    end
  end

  defp missing_flag!(name) do
    Mix.shell().error("codegen.loop: #{name} is required")
    exit({:shutdown, 2})
  end

  # Gate: `verify_commit_landed/2` below.

  # Ship-gate floor for the SOLO path (the drain's twin floor already lives
  # in `LoopQueueDrain.handle_exit_zero/8`): `OrchestrationLoop.run/1` can
  # return a bare `:ok` with no work having actually landed — with the
  # turn-0 realized-check preflight removed, the only remaining source of
  # that would be a defect in the role chain itself, but this floor exists
  # so such a defect fails LOUD (refuse the ship) instead of silently
  # shipping an empty cycle. Requires HEAD to have moved AND the prior HEAD
  # to be an ancestor of the new one (non-orphaning — rules out a rebase
  # that discarded history rather than adding to it). Fails OPEN on a
  # non-git cwd / unborn HEAD (mirrors `assert_clean_tree!/1`'s own
  # fail-open posture for the same non-git case) — synthetic test cwds and
  # the codegen self-build's own root are the intended beneficiaries.
  @doc false
  @spec git_head(String.t()) :: {:ok, String.t()} | :unborn
  def git_head(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _nonzero} -> :unborn
    end
  end

  # All three success arms return the SAME shape, {:ok, sha | nil} — nil is
  # the non-git/unborn carve-out (mirrors assert_clean_tree!/1's fail-open
  # posture) and is exactly the value maybe_ship_pitch/4 threads into
  # LoopQueue.record_ship/4's own fail-open clause. One value, one meaning,
  # rather than a second code path that could drift from it.
  @doc false
  @spec verify_commit_landed({:ok, String.t()} | :unborn, String.t()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def verify_commit_landed(:unborn, _cwd), do: {:ok, nil}

  def verify_commit_landed({:ok, before_sha}, cwd) do
    case git_head(cwd) do
      :unborn ->
        {:ok, nil}

      {:ok, after_sha} ->
        cond do
          after_sha == before_sha ->
            {:error, "HEAD did not advance (no commit this cycle)"}

          not ancestor?(cwd, before_sha, after_sha) ->
            {:error,
             "HEAD advanced but #{before_sha} is not an ancestor of #{after_sha} (history rewritten, not extended)"}

          true ->
            {:ok, after_sha}
        end
    end
  end

  defp ancestor?(cwd, ancestor_sha, descendant_sha) do
    case System.cmd(
           "git",
           ["-C", cwd, "merge-base", "--is-ancestor", ancestor_sha, descendant_sha],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end

  # Retire follows git truth: on a VERIFIED landing (the caller already
  # proved HEAD advanced + ancestor-extended via verify_commit_landed/2),
  # the pitch leaves ready/or building/ UNCONDITIONALLY — record_ship +
  # rename run FIRST. The clean-tree check runs SECOND, as a loud non-fatal
  # signal (exit @dirty_tree_exit_code) rather than a gate that could strand
  # already-landed work back in a dispatchable directory. See
  # codegen/pitches/shipped/a-landed-pitch-cannot-be-handed-out-again.md —
  # a pitch whose work landed must never be handed to a builder again, and
  # blocking the retire on tree cleanliness never protected those dirty
  # files anyway (they stay dirty either way); it only decided whether the
  # landed pitch remains dispatchable.
  defp ship_ready_pitch(src, dst, cwd, slug, before_sha, after_sha) do
    cond do
      not File.exists?(src) and File.exists?(dst) ->
        :ok

      true ->
        # Frontmatter, then the mv — see LoopQueue.record_ship/4
        # moduledoc for why this order is load-bearing (a stranded
        # shipped_sha: on a still-ready/ pitch is read by the NEXT
        # build's prompt as "already shipped").
        LoopQueue.record_ship(cwd, slug, before_sha, after_sha)
        File.mkdir_p!(Path.dirname(dst))
        File.rename!(src, dst)
        warn_dirty_after_retire(cwd)
        :ok
    end
  end

  # Loud, non-fatal-to-the-ship signal: the pitch already left ready/
  # (unconditionally, above) — a dirty tree here can no longer strand it.
  # Prints the dirty status and exits @dirty_tree_exit_code so the drain
  # (LoopQueueDrain) can classify this as shipped-with-warning rather than
  # a failed pitch to requeue. Fails open (returns normally, no exit) on a
  # non-git cwd — mirrors the removed assert_clean_tree!/1's own posture.
  defp warn_dirty_after_retire(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {_out, 0} ->
        {status, _} =
          System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true)

        if String.trim(status) != "" do
          Mix.shell().error(
            "codegen.loop: COMMITTED and RETIRED — working tree not clean:\n#{status}"
          )

          exit({:shutdown, @dirty_tree_exit_code})
        end

        :ok

      # not a git repo / git unavailable — fail open (mirrors legacy clean-tree-before-ship.sh)
      {_out, _nonzero} ->
        :ok
    end
  end
end
