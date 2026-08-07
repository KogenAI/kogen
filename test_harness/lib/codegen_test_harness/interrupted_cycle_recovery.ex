defmodule CodegenTestHarness.InterruptedCycleRecovery do
  @moduledoc """
  Recovers one interrupted `building/` claim without losing dirty work or
  guessing lifecycle ownership.
  """

  alias CodegenTestHarness.{LoopQueue, OrchestrationLoop}

  @type recovery ::
          :none
          | {:resume, String.t()}
          | {:requeued, String.t(), :clean | {:parked, String.t()}}
  @type park_error :: %{location: String.t(), reason: String.t()}

  @journal_keys ~w(branch original_ref slug stage transaction_id updated_at)
  @parking_stages ~w(parking parked history_written resume_pending)

  @spec reconcile(keyword()) :: {:ok, recovery()} | {:error, String.t()}
  def reconcile(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    building_dir = Keyword.get(opts, :building_dir, pitches_dir(cwd, "building"))
    ready_dir = Keyword.get(opts, :ready_dir, pitches_dir(cwd, "ready"))
    journal = Keyword.get(opts, :journal_path, journal_path(cwd))
    roles = Keyword.fetch!(opts, :roles)

    with {:ok, claims} <- building_claims(building_dir),
         journal_result <- read_journal(journal),
         {:ok, result} <-
           reconcile_claims(claims, cwd, ready_dir, journal, journal_result, roles, opts) do
      {:ok, result}
    end
  end

  @spec park_worktree(String.t(), String.t(), String.t(), :strict | :warning) ::
          {:ok, :clean | {:parked, String.t()}} | {:error, park_error()}
  def park_worktree(cwd, slug, namespace, policy) when policy in [:strict, :warning] do
    transaction_id = "#{namespace}:#{slug}:#{utc_stamp()}-#{System.unique_integer([:positive])}"
    park_worktree(cwd, slug, namespace, policy, transaction_id)
  end

  @doc false
  @spec complete_resume_claim!(String.t(), String.t()) :: :ok
  def complete_resume_claim!(cwd, slug) do
    path = journal_path(cwd)

    case read_journal(path) do
      {:ok, %{"slug" => ^slug, "stage" => "resume_pending"}} ->
        File.rm!(path)
        :ok

      :absent ->
        :ok

      {:ok, _journal} ->
        raise "InterruptedCycleRecovery: resume journal does not belong to #{slug}"

      {:error, reason} ->
        raise "InterruptedCycleRecovery: invalid resume journal: #{reason}"
    end
  end

  defp reconcile_claims([], _cwd, _ready_dir, _journal, :absent, _roles, _opts), do: {:ok, :none}

  defp reconcile_claims([], cwd, ready_dir, journal_path, {:ok, journal}, roles, opts) do
    ready_claim = Path.join(ready_dir, "#{journal["slug"]}.md")

    with :ok <- validate_journal(journal),
         "resume_pending" <- journal["stage"],
         true <- File.exists?(ready_claim) do
      resume_pending(journal, ready_claim, cwd, ready_dir, journal_path, roles, opts)
    else
      false ->
        {:error,
         "interrupted recovery journal #{journal_path} has no ready claim at #{ready_claim} for #{inspect(journal["slug"])}"}

      :error ->
        {:error, "interrupted recovery journal #{journal_path}: malformed journal fields"}

      _ ->
        {:error,
         "interrupted recovery journal #{journal_path} has no matching building claim for #{inspect(journal["slug"])}"}
    end
  end

  defp reconcile_claims([], _cwd, _ready_dir, journal_path, {:error, reason}, _roles, _opts) do
    {:error, "interrupted recovery journal #{journal_path}: #{inspect(reason)}"}
  end

  defp reconcile_claims([claim], cwd, ready_dir, path, journal_result, roles, opts) do
    slug = Path.basename(claim, ".md")

    case journal_result do
      :absent ->
        reconcile_new_claim(claim, slug, cwd, ready_dir, path, roles, opts)

      {:ok, journal} ->
        resume_transaction(journal, claim, cwd, ready_dir, path, roles, opts)

      {:error, reason} ->
        {:error, "interrupted recovery journal #{path}: #{inspect(reason)}"}
    end
  end

  defp reconcile_claims(claims, _cwd, _ready_dir, _journal, _journal_result, _roles, _opts) do
    names = claims |> Enum.map(&Path.basename/1) |> Enum.join(", ")
    {:error, "interrupted recovery refused: multiple building pitches: #{names}"}
  end

  defp reconcile_new_claim(claim, slug, cwd, ready_dir, path, roles, opts) do
    checkpoint_opts = opts |> Keyword.put(:slug, slug) |> Keyword.put(:cwd, cwd)

    case OrchestrationLoop.resume_checkpoint(cwd, roles, checkpoint_opts) do
      {:resume, _role, _state} ->
        journal = new_journal(slug, "", original_ref!(cwd), "resume_pending")
        write_journal!(path, journal)
        move_to_ready!(claim, ready_dir)
        {:ok, {:resume, slug}}

      :full ->
        claim_body = File.read!(claim)
        journal = new_journal(slug, "", original_ref!(cwd), "parking")
        write_journal!(path, journal)

        case park_worktree(cwd, slug, "recovery/interrupted", :strict, journal["transaction_id"]) do
          {:ok, result} ->
            branch = result_branch(result)
            parked = %{journal | "branch" => branch, "stage" => "parked", "updated_at" => now()}
            write_journal!(path, parked)
            restored_claim = Path.join(ready_dir, Path.basename(claim))
            File.mkdir_p!(ready_dir)
            File.write!(restored_claim, claim_body)
            write_history!(restored_claim, parked, result)

            history_written = %{parked | "stage" => "history_written", "updated_at" => now()}
            write_journal!(path, history_written)
            finish_requeue!(claim, ready_dir, cwd, path)
            {:ok, {:requeued, slug, result}}

          {:error, %{location: location, reason: reason}} ->
            {:error, "interrupted recovery could not park #{location}: #{reason}"}
        end
    end
  end

  defp adopt_parking_transaction(cwd, journal) do
    transaction_id = journal["transaction_id"]

    with {:ok, branches} <- transaction_branches(cwd, transaction_id),
         {:ok, stashes} <- transaction_stashes(cwd, transaction_id) do
      case {branches, stashes} do
        {[branch], []} ->
          with {:ok, _} <- git(cwd, ["checkout", journal["original_ref"]]) do
            {:ok, branch}
          end

        {[], [stash]} ->
          branch = "recovery/interrupted/#{journal["slug"]}/#{utc_stamp()}"

          with :ok <- ensure_branch_absent(cwd, branch),
               {:ok, _} <- git(cwd, ["stash", "branch", branch, stash]),
               {:ok, _} <- git(cwd, ["add", "-A"]),
               {:ok, _} <-
                 git(cwd, [
                   "commit",
                   "--allow-empty",
                   "-m",
                   "#{transaction_id} parked WIP from #{journal["original_ref"]}"
                 ]),
               {:ok, _} <- git(cwd, ["checkout", journal["original_ref"]]) do
            {:ok, branch}
          end

        {[], []} ->
          {:error, "parking transaction #{transaction_id} has no matching stash or branch"}

        _ ->
          {:error, "parking transaction #{transaction_id} has ambiguous matching stash or branch"}
      end
    end
  end

  defp transaction_branches(cwd, transaction_id) do
    with {:ok, output} <-
           git(cwd, [
             "for-each-ref",
             "--format=%(refname:short)%00%(contents:subject)",
             "refs/heads"
           ]) do
      branches =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn entry ->
          case String.split(entry, <<0>>, parts: 2) do
            [branch, subject] when is_binary(subject) ->
              if String.contains?(subject, transaction_id), do: [branch], else: []

            _ ->
              []
          end
        end)

      {:ok, branches}
    end
  end

  defp transaction_stashes(cwd, transaction_id) do
    with {:ok, output} <- git(cwd, ["stash", "list", "--format=%gd%x00%s"]) do
      stashes =
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn entry ->
          case String.split(entry, <<0>>, parts: 2) do
            [stash, subject] when is_binary(subject) ->
              if String.contains?(subject, transaction_id), do: [stash], else: []

            _ ->
              []
          end
        end)

      {:ok, stashes}
    end
  end

  defp resume_pending(journal, claim, cwd, ready_dir, path, roles, opts) do
    slug = journal["slug"]
    checkpoint_opts = opts |> Keyword.put(:cwd, cwd) |> Keyword.put(:slug, slug)

    case OrchestrationLoop.resume_checkpoint(cwd, roles, checkpoint_opts) do
      {:resume, _role, _state} ->
        ready_claim = Path.join(ready_dir, Path.basename(claim))

        if claim != ready_claim do
          move_to_ready!(claim, ready_dir)
        end

        {:ok, {:resume, slug}}

      :full ->
        # The checkpoint was valid when recovery first moved the claim back
        # to ready, but is no longer resumable (most importantly: its tree is
        # now clean because the recovered bytes already landed). Leaving the
        # resume_pending journal in place makes every later startup fail on
        # the same stale decision. Retire the checkpoint transaction and
        # return the claim to the ordinary full-run lane without touching
        # HEAD; any already-landed descendant commit remains intact.
        finish_requeue!(claim, ready_dir, cwd, path)
        {:ok, {:requeued, slug, :clean}}
    end
  end

  defp resume_parking(journal, claim, cwd, ready_dir, path) do
    claim_body = File.read!(claim)

    with {:ok, branch} <- adopt_parking_transaction(cwd, journal),
         :ok <- verify_parked_branch(cwd, %{journal | "branch" => branch}) do
      restored_claim = Path.join(ready_dir, Path.basename(claim))
      File.mkdir_p!(ready_dir)

      history_claim =
        cond do
          File.exists?(claim) ->
            claim

          File.exists?(restored_claim) ->
            restored_claim

          true ->
            File.write!(restored_claim, claim_body)
            restored_claim
        end

      parked = %{journal | "branch" => branch, "stage" => "parked", "updated_at" => now()}
      write_journal!(path, parked)
      write_history!(history_claim, parked, {:parked, branch})
      write_journal!(path, %{parked | "stage" => "history_written", "updated_at" => now()})
      finish_requeue!(claim, ready_dir, cwd, path)
      {:ok, {:requeued, journal["slug"], {:parked, branch}}}
    else
      {:error, reason} -> {:error, "interrupted recovery journal #{path}: #{reason}"}
    end
  end

  defp resume_transaction(journal, claim, cwd, ready_dir, path, roles, opts) do
    with :ok <- validate_journal(journal),
         slug <- Map.fetch!(journal, "slug"),
         ^slug <- Path.basename(claim, ".md") do
      case journal["stage"] do
        "resume_pending" ->
          resume_pending(journal, claim, cwd, ready_dir, path, roles, opts)

        "parking" ->
          resume_parking(journal, claim, cwd, ready_dir, path)

        "parked" ->
          verify_parked_branch(cwd, journal)
          write_history!(claim, journal, {:parked, journal["branch"]})
          write_journal!(path, %{journal | "stage" => "history_written", "updated_at" => now()})
          finish_requeue!(claim, ready_dir, cwd, path)
          {:ok, {:requeued, slug, {:parked, journal["branch"]}}}

        "history_written" ->
          verify_parked_branch(cwd, journal)
          finish_requeue!(claim, ready_dir, cwd, path)
          {:ok, {:requeued, slug, {:parked, journal["branch"]}}}

        stage ->
          {:error, "interrupted recovery journal #{path}: unknown stage #{inspect(stage)}"}
      end
    else
      :error -> {:error, "interrupted recovery journal #{path} belongs to another building claim"}
      {:error, reason} -> {:error, "interrupted recovery journal #{path}: #{reason}"}
    end
  end

  defp finish_requeue!(claim, ready_dir, cwd, path) do
    ready_claim = Path.join(ready_dir, Path.basename(claim))

    cond do
      claim == ready_claim and File.exists?(ready_claim) -> :ok
      File.exists?(ready_claim) and File.exists?(claim) -> File.rm!(claim)
      File.exists?(claim) -> move_to_ready!(claim, ready_dir)
      File.exists?(ready_claim) -> :ok
      true -> raise "InterruptedCycleRecovery: missing claim #{claim} during requeue"
    end

    clear_checkpoint!(cwd)
    File.rm!(path)
  end

  defp park_worktree(cwd, slug, namespace, _policy, transaction_id) do
    with {:ok, status} <- git(cwd, ["status", "--porcelain", "--untracked-files=all"]),
         {:dirty, status} when status != "" <- {:dirty, status},
         {:ok, original_ref} <- original_ref(cwd),
         branch = "#{namespace}/#{slug}/#{utc_stamp()}",
         :ok <- ensure_branch_absent(cwd, branch),
         {:ok, _} <- git(cwd, ["stash", "push", "--include-untracked", "-m", transaction_id]),
         {:ok, _} <- git(cwd, ["stash", "branch", branch, "stash@{0}"]),
         {:ok, _} <- git(cwd, ["add", "-A"]),
         {:ok, _} <-
           git(cwd, [
             "commit",
             "--allow-empty",
             "-m",
             "#{transaction_id} parked WIP from #{original_ref}"
           ]),
         {:ok, _} <- git(cwd, ["checkout", original_ref]) do
      {:ok, {:parked, branch}}
    else
      {:dirty, ""} -> {:ok, :clean}
      {:error, reason} -> {:error, %{location: cwd, reason: reason}}
    end
  end

  defp building_claims(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        claims =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.sort()

        {:ok, claims}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot read building directory #{dir}: #{inspect(reason)}"}
    end
  end

  defp validate_journal(journal) when is_map(journal) do
    if Map.keys(journal) |> Enum.sort() == @journal_keys and
         is_binary(journal["transaction_id"]) and journal["transaction_id"] != "" and
         is_binary(journal["slug"]) and journal["slug"] != "" and
         is_binary(journal["branch"]) and is_binary(journal["original_ref"]) and
         journal["original_ref"] != "" and journal["stage"] in @parking_stages and
         is_binary(journal["updated_at"]) and journal["updated_at"] != "" do
      :ok
    else
      {:error, "malformed journal fields"}
    end
  end

  defp validate_journal(_), do: {:error, "malformed JSON object"}

  defp verify_parked_branch(_cwd, %{"branch" => ""}), do: :ok

  defp verify_parked_branch(cwd, %{"branch" => branch, "transaction_id" => transaction_id}) do
    with {:ok, message} <- git(cwd, ["log", "-1", "--format=%B", branch]),
         true <- String.contains?(message, transaction_id) do
      :ok
    else
      false -> {:error, "parked branch #{branch} lacks transaction identity"}
      {:error, reason} -> {:error, "cannot verify parked branch #{branch}: #{reason}"}
    end
  end

  defp write_history!(claim, journal, result) do
    branch = result_branch(result)
    recovery = if branch == "", do: "none (tree clean)", else: branch

    row =
      "| interrupted recovery | #{utc_stamp()} | unaccountable | checkpoint=#{journal["stage"]}; recovery=#{recovery}; next=operator-inspection-required |"

    LoopQueue.write_history_row!(claim, "Build failure history", row)
  end

  defp read_journal(path) do
    case File.read(path) do
      {:error, :enoent} ->
        :absent

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, journal} -> {:ok, journal}
          {:error, _reason} -> {:error, "malformed JSON"}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp write_journal!(path, journal) do
    File.mkdir_p!(Path.dirname(path))

    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}"
      )

    File.write!(temporary, Jason.encode!(journal))
    File.rename!(temporary, path)
  end

  defp clear_checkpoint!(cwd) do
    pending = Path.join([cwd, "codegen", "gate-pending"])

    for name <- ["gate-result.json", "cycle-state.json"] do
      case File.rm(Path.join(pending, name)) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          raise "InterruptedCycleRecovery: cannot remove #{name}: #{inspect(reason)}"
      end
    end
  end

  defp move_to_ready!(claim, ready_dir) do
    File.mkdir_p!(ready_dir)
    File.rename!(claim, Path.join(ready_dir, Path.basename(claim)))
  end

  defp ensure_branch_absent(cwd, branch) do
    case git(cwd, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, _} -> {:error, "recovery branch already exists: #{branch}"}
      {:error, _} -> :ok
    end
  end

  defp original_ref!(cwd) do
    case original_ref(cwd) do
      {:ok, ref} -> ref
      {:error, reason} -> raise "InterruptedCycleRecovery: cannot resolve original ref: #{reason}"
    end
  end

  defp original_ref(cwd) do
    case git(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, ""} -> git(cwd, ["rev-parse", "HEAD"])
      {:ok, ref} -> {:ok, ref}
      {:error, _} -> git(cwd, ["rev-parse", "HEAD"])
    end
  end

  defp git(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  # `git diff --binary` output MUST be captured byte-exact — `git/2` above
  # is unsuitable for two reasons: `stderr_to_stdout: true` can splice
  # unrelated stderr noise into the patch bytes, and `String.trim/1` can
  # strip a trailing newline `git apply` needs to parse the final hunk.
  # stderr is captured SEPARATELY (never merged into stdout) so a non-zero
  # exit still reports a clean error message.
  @spec git_raw_diff(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, String.t()}
  defp git_raw_diff(cwd, from_sha, to_sha) do
    case System.cmd("git", ["-C", cwd, "diff", "--binary", from_sha, to_sha],
           stderr_to_stdout: false
         ) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp new_journal(slug, branch, original_ref, stage) do
    %{
      "branch" => branch,
      "original_ref" => original_ref,
      "slug" => slug,
      "stage" => stage,
      "transaction_id" =>
        "interrupted-recovery-#{utc_stamp()}-#{System.unique_integer([:positive])}",
      "updated_at" => now()
    }
  end

  defp result_branch(:clean), do: ""
  defp result_branch({:parked, branch}), do: branch
  defp pitches_dir(cwd, state), do: Path.join([cwd, "codegen", "pitches", state])

  defp journal_path(cwd),
    do: Path.join([cwd, "codegen", "gate-pending", "interrupted-recovery.json"])

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp utc_stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

  # ── Per-transaction recovery dossiers ──────────────────────────────────────
  #
  # Replaces the single global journal above as the authority for a
  # CONTROLLED terminal failure (direct or queue): one immutable branch
  # commit + one versioned JSON dossier per transaction under
  # `codegen/gate-pending/recoveries/<slug>/<transaction-id>.json`. Unlike
  # the journal (one record, slug-agnostic, forced-priority-capable), a
  # dossier is identified by the CLAIMED/SELECTED pitch's own basename +
  # scope — never by branch name or checkpoint slug (see pitch "restarted
  # builds resume owned work" probe 4: a historical recovery commit parked
  # fleet-control bytes under the WRONG slug's journal). Dormant by
  # default: writing a dossier never reorders queue/direct selection.

  @dossier_schema_version 1
  @dossier_stages ~w(parking parked history_written ready materialized superseded completed)a

  @type dossier_stage ::
          :parking
          | :parked
          | :history_written
          | :ready
          | :materialized
          | :superseded
          | :completed
  @type disposition :: :exact | :advanced | :operator | :conflict

  @doc """
  Strict, journaled, fail-closed parking of a CONTROLLED terminal failure
  (direct `run/1`/commit-verification error, or a queue terminal failure).
  Called BEFORE the caller restores its claim to `ready/` — a park failure
  must never prevent that restore (see codegen.loop.ex `run_claimed_cycle/8`
  and `LoopQueueDrain`'s terminal arms).

  `opts`:
    - `:cwd` (required)
    - `:pitch_path` (required) — the claimed pitch's absolute path (source
      of slug + `scope:` authority)
    - `:slug` (required) — the claimed/selected pitch basename; NEVER
      derived from cycle-state.json or branch name
    - `:namespace` (required) — `"recovery/interrupted"` (direct/crash) or
      `"queue-fail"` (queue terminal failure)
    - `:cause` (optional) — fresh terminal-cause string; absent/nil records
      `"unknown"` and forces developer reconciliation at
      materialization time, never a shortcut to exact-base resume
    - `:cycle_state` (optional) — the last completed cycle-state string
      (`"GATED"|"REVIEWED"|"CURATED"` or nil), snapshotted for later role
      selection

  Returns `{:ok, dossier}` (the written dossier map) or `{:error, reason}`.
  Parking always preserves bytes. When the changed paths reach beyond the
  pitch's declared `scope:`, the dossier records the expansion
  (`ownership: "expanded"` + `scope_expansion: [paths]`) and the pitch's
  history row names it — it does NOT restrict later materialization.
  """
  @spec park_failure(keyword()) :: {:ok, map()} | {:error, String.t()}
  def park_failure(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    pitch_path = Keyword.fetch!(opts, :pitch_path)
    slug = Keyword.fetch!(opts, :slug)
    namespace = Keyword.fetch!(opts, :namespace)
    cause = Keyword.get(opts, :cause) || "unknown"
    cycle_state = Keyword.get(opts, :cycle_state)

    transaction_id = "#{namespace}:#{slug}:#{utc_stamp()}-#{System.unique_integer([:positive])}"

    with :ok <- refuse_if_active_dossier(cwd, slug),
         {:ok, source_base_sha} <- git(cwd, ["rev-parse", "HEAD"]),
         :ok <-
           write_dossier!(
             cwd,
             slug,
             transaction_id,
             parking_dossier(
               transaction_id,
               slug,
               namespace,
               pitch_path,
               source_base_sha,
               cause,
               cycle_state
             )
           ),
         {:ok, status} <- git(cwd, ["status", "--porcelain", "--untracked-files=all"]) do
      if String.trim(status) == "" do
        # Nothing to park — dossier records a clean parking (no recovery
        # commit possible); still legal, still fail-closed on identity.
        dossier =
          parked_dossier(
            slug,
            transaction_id,
            namespace,
            pitch_path,
            source_base_sha,
            cause,
            cycle_state,
            nil,
            nil,
            []
          )

        with :ok <- write_dossier!(cwd, slug, transaction_id, dossier) do
          finish_park!(cwd, pitch_path, slug, transaction_id, dossier)
        end
      else
        do_park_dirty_tree(
          cwd,
          pitch_path,
          slug,
          namespace,
          transaction_id,
          source_base_sha,
          cause,
          cycle_state
        )
      end
    end
  end

  defp do_park_dirty_tree(
         cwd,
         pitch_path,
         slug,
         namespace,
         transaction_id,
         source_base_sha,
         cause,
         cycle_state
       ) do
    # `System.unique_integer([:positive])` disambiguator: `utc_stamp/0` is
    # second-granularity, so two failures for the SAME slug within one
    # second (e.g. a successor transaction chained right after its
    # predecessor) would otherwise collide on an identical branch name and
    # `ensure_branch_absent/2` would refuse the second park.
    branch = "#{namespace}/#{slug}/#{utc_stamp()}-#{System.unique_integer([:positive])}"

    # NOTE: bare `--include-untracked`, deliberately NO explicit `.`
    # pathspec — an explicit pathspec flips `git stash push` into add-like
    # semantics, which REFUSES on the repo's own gitignored `codegen/` dir
    # ("The following paths are ignored ... Use -f"). Pathspec-free stash
    # already skips gitignored files silently, which is exactly the
    # behavior a park of a codegen self-build (or any downstream app with a
    # gitignored codegen/) needs.
    with {:ok, original_ref} <- original_ref(cwd),
         :ok <- ensure_branch_absent(cwd, branch),
         {:ok, _} <- git(cwd, ["stash", "push", "--include-untracked", "-m", transaction_id]),
         {:ok, _} <- git(cwd, ["stash", "branch", branch, "stash@{0}"]),
         {:ok, _} <- git(cwd, ["add", "-A"]),
         {:ok, _} <-
           git(cwd, [
             "commit",
             "--allow-empty",
             "-m",
             "#{transaction_id} parked WIP from #{original_ref}"
           ]),
         {:ok, recovery_commit} <- git(cwd, ["rev-parse", "HEAD"]),
         {:ok, recovery_tree_sha} <- git(cwd, ["rev-parse", "#{recovery_commit}^{tree}"]),
         {:ok, _} <- git(cwd, ["checkout", original_ref]) do
      {:ok, changed_paths} =
        git(cwd, ["diff", "--name-only", "#{source_base_sha}..#{recovery_commit}"])

      paths = changed_paths |> String.split("\n", trim: true)

      {scope_verdict, undeclared} = classify_scope(slug, pitch_path, paths)

      dossier =
        slug
        |> parked_dossier(
          transaction_id,
          namespace,
          pitch_path,
          source_base_sha,
          cause,
          cycle_state,
          branch,
          recovery_commit,
          paths
        )
        |> Map.put("recovery_tree_sha", recovery_tree_sha)
        |> Map.put("ownership", scope_verdict)
        |> Map.put("scope_expansion", undeclared)

      with :ok <- write_dossier!(cwd, slug, transaction_id, dossier) do
        finish_park!(cwd, pitch_path, slug, transaction_id, dossier)
      end
    else
      {:error, reason} -> {:error, "park_failure could not preserve #{slug}'s tree: #{reason}"}
    end
  end

  # Extracts file paths from `git status --porcelain --untracked-files=all`
  # output — includes UNTRACKED new files (unlike `git diff --name-only`,
  # which only reports changes to already-tracked paths). Each line is a
  # 2-char status code, a space, then the path (a rename line's `a -> b`
  # form is split on the arrow and only the destination `b` is kept).
  @spec porcelain_paths(String.t()) :: [String.t()]
  defp porcelain_paths(status) do
    status
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      path = line |> String.slice(3..-1//1)

      case String.split(path, " -> ") do
        [_from, to] -> to
        [only] -> only
      end
    end)
  end

  # Classifies the parked transaction's changed paths against the pitch's
  # own `scope:` frontmatter and returns `{verdict, undeclared_paths}`.
  # The verdict is REPORT-ONLY: `"ok"` when the pitch declares no scope (an
  # unrouted pitch has no boundary) or every changed path falls inside a
  # declared exact-file/directory-prefix entry; `"expanded"` when the
  # developer also touched paths the pitch did not declare; `"unknown"`
  # when the pitch could not be read or parsed.
  #
  # A non-`"ok"` verdict NEVER discards, withholds, or refuses to restore
  # bytes. Planning cannot enumerate every line an implementation needs,
  # and the REVIEWER is the mechanism that adjudicates whether an expansion
  # was warranted — recovery must not re-litigate that verdict with a
  # cruder check. Recovery's job is to record what happened (dossier
  # `scope_expansion` + the pitch's build-failure history row) so a human
  # can see it.
  @spec classify_scope(String.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  defp classify_scope(slug, pitch_path, paths) do
    case LoopQueue.parse_scope(slug, pitch_path) do
      {:ok, nil} ->
        {"ok", []}

      {:ok, []} ->
        scope_verdict(paths)

      {:ok, scope} ->
        paths |> Enum.reject(&path_in_scope?(&1, scope)) |> scope_verdict()
    end
  rescue
    # An unreadable/unparseable pitch is a REPORTING gap, never a reason to
    # strand finished work: record `"unknown"` and let materialization run.
    _ -> {"unknown", []}
  end

  @spec scope_verdict([String.t()]) :: {String.t(), [String.t()]}
  defp scope_verdict([]), do: {"ok", []}
  defp scope_verdict(undeclared), do: {"expanded", undeclared}

  @spec path_in_scope?(String.t(), [String.t()]) :: boolean()
  defp path_in_scope?(path, scope) do
    Enum.any?(scope, fn entry ->
      path == entry or String.starts_with?(path, String.trim_trailing(entry, "/") <> "/")
    end)
  end

  defp finish_park!(cwd, pitch_path, slug, transaction_id, dossier) do
    with :ok <- write_history_row(pitch_path, dossier),
         history_dossier =
           Map.merge(dossier, %{"stage" => "history_written", "updated_at" => now()}),
         :ok <- write_dossier!(cwd, slug, transaction_id, history_dossier),
         ready_dossier = Map.merge(history_dossier, %{"stage" => "ready", "updated_at" => now()}),
         :ok <- write_dossier!(cwd, slug, transaction_id, ready_dossier) do
      # Parking replaces this failed cycle's live continuation with the
      # recovery dossier. Its checkpoint can no longer describe work that is
      # safe to resume, so remove it before the next loop invocation can let
      # a stale GATED/clear pair override the dossier's recovery role.
      clear_checkpoint!(cwd)
      {:ok, ready_dossier}
    end
  end

  defp write_history_row(pitch_path, dossier) do
    recovery_commit = dossier["recovery_commit"] || "none (tree clean)"

    # Scope expansion is REPORTED here (never refused): the row names the
    # undeclared paths so the next human — or the reviewer on the re-run —
    # can see exactly what the implementation reached beyond the pitch.
    expansion =
      case dossier["scope_expansion"] || [] do
        [] -> ""
        paths -> "; scope_expansion=#{Enum.join(paths, ", ")}"
      end

    row =
      "| interrupted recovery | #{utc_stamp()} | unaccountable | " <>
        "txn=#{dossier["transaction_id"]}; recovery=#{recovery_commit}; " <>
        "ownership=#{dossier["ownership"] || "ok"}#{expansion} |"

    LoopQueue.write_history_row!(pitch_path, "Build failure history", row)
    :ok
  rescue
    e -> {:error, "history write failed: #{Exception.message(e)}"}
  end

  defp parking_dossier(
         transaction_id,
         slug,
         namespace,
         pitch_path,
         source_base_sha,
         cause,
         cycle_state
       ) do
    %{
      "schema_version" => @dossier_schema_version,
      "transaction_id" => transaction_id,
      "slug" => slug,
      "namespace" => namespace,
      "pitch_path" => pitch_path,
      "source_base_sha" => source_base_sha,
      "cause" => cause,
      "cycle_state" => cycle_state,
      "recovery_ref" => nil,
      "recovery_commit" => nil,
      "recovery_tree_sha" => nil,
      "changed_paths" => [],
      "ownership" => nil,
      "operator_ref" => nil,
      "operator_tree_sha" => nil,
      "successor_transaction_id" => nil,
      "stage" => "parking",
      "updated_at" => now()
    }
  end

  defp parked_dossier(
         slug,
         transaction_id,
         namespace,
         pitch_path,
         source_base_sha,
         cause,
         cycle_state,
         branch,
         recovery_commit,
         paths
       ) do
    %{
      "schema_version" => @dossier_schema_version,
      "transaction_id" => transaction_id,
      "slug" => slug,
      "namespace" => namespace,
      "pitch_path" => pitch_path,
      "source_base_sha" => source_base_sha,
      "cause" => cause,
      "cycle_state" => cycle_state,
      "recovery_ref" => branch,
      "recovery_commit" => recovery_commit,
      "recovery_tree_sha" => nil,
      "changed_paths" => paths,
      "ownership" => if(branch, do: nil, else: "ok"),
      "operator_ref" => nil,
      "operator_tree_sha" => nil,
      "successor_transaction_id" => nil,
      "stage" => "parked",
      "updated_at" => now()
    }
  end

  # Refuses (rather than silently overwriting) when `slug` already has an
  # UNRESOLVED dossier (`parking` through `materialized` — everything short
  # of `superseded`/`completed`). Multiple active dossiers for one slug make
  # ownership ambiguous; the caller must resolve the prior transaction
  # first (mark it `superseded` via a successor, or let it reach
  # `completed`).
  @spec refuse_if_active_dossier(String.t(), String.t()) :: :ok | {:error, String.t()}
  defp refuse_if_active_dossier(cwd, slug) do
    case list_dossiers(cwd, slug) do
      {:ok, dossiers} ->
        active =
          Enum.filter(dossiers, fn d ->
            stage = dossier_stage_atom(d["stage"])
            stage not in [:superseded, :completed]
          end)

        case active do
          [] -> :ok
          [_one] -> {:ok, :chain}
          _many -> {:error, "multiple active recovery dossiers for #{slug} — refusing"}
        end

      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      :ok -> :ok
      {:ok, :chain} -> supersede_active!(cwd, slug)
      {:error, reason} -> {:error, reason}
    end
  end

  # A slug that already has exactly one active dossier and fails again gets
  # a NEW transaction chained to the old one: the predecessor is marked
  # `superseded` (with `successor_transaction_id` set once the new
  # transaction exists), never overwritten in place. The predecessor's ref
  # never moves; only the dossier's `stage` changes.
  defp supersede_active!(cwd, slug) do
    with {:ok, dossiers} <- list_dossiers(cwd, slug) do
      case Enum.find(dossiers, fn d ->
             dossier_stage_atom(d["stage"]) not in [:superseded, :completed]
           end) do
        nil ->
          :ok

        predecessor ->
          superseded = Map.merge(predecessor, %{"stage" => "superseded", "updated_at" => now()})
          write_dossier!(cwd, slug, predecessor["transaction_id"], superseded)
      end
    end
  end

  defp dossier_stage_atom(stage) when is_binary(stage) do
    atom = String.to_existing_atom(stage)
    if atom in @dossier_stages, do: atom, else: raise("unknown dossier stage #{stage}")
  rescue
    ArgumentError -> raise "InterruptedCycleRecovery: unknown dossier stage #{inspect(stage)}"
  end

  @spec list_dossiers(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  defp list_dossiers(cwd, slug) do
    dir = dossier_dir(cwd, slug)

    case File.ls(dir) do
      {:ok, entries} ->
        dossiers =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn name ->
            path = Path.join(dir, name)

            case File.read(path) do
              {:ok, body} ->
                case Jason.decode(body) do
                  {:ok, %{"schema_version" => @dossier_schema_version} = decoded} ->
                    decoded

                  {:ok, _other} ->
                    raise "InterruptedCycleRecovery: unknown dossier schema at #{path}"

                  {:error, _} ->
                    raise "InterruptedCycleRecovery: malformed dossier JSON at #{path}"
                end

              {:error, reason} ->
                raise "InterruptedCycleRecovery: cannot read dossier #{path}: #{inspect(reason)}"
            end
          end)

        {:ok, dossiers}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot read recovery dossier dir #{dir}: #{inspect(reason)}"}
    end
  end

  @doc """
  Reads the single ACTIVE (non-`superseded`/`completed`) dossier for `slug`,
  if any. `{:ok, nil}` when none exists (the common case — most slugs never
  fail). `{:error, reason}` on multiple active dossiers (ambiguous) or a
  malformed/unreadable dossier directory.
  """
  @spec active_dossier(String.t(), String.t()) :: {:ok, map() | nil} | {:error, String.t()}
  def active_dossier(cwd, slug) do
    with {:ok, dossiers} <- list_dossiers(cwd, slug) do
      active =
        Enum.filter(dossiers, fn d ->
          dossier_stage_atom(d["stage"]) not in [:superseded, :completed]
        end)

      case active do
        [] -> {:ok, nil}
        [one] -> {:ok, one}
        _many -> {:error, "multiple active recovery dossiers for #{slug} — refusing"}
      end
    end
  end

  defp dossier_dir(cwd, slug), do: Path.join([cwd, "codegen", "gate-pending", "recoveries", slug])

  defp dossier_path(cwd, slug, transaction_id) do
    # transaction_id contains `:` and `/` (namespace prefix) — sanitize to a
    # filesystem-safe basename while staying unique per transaction.
    safe = transaction_id |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    Path.join(dossier_dir(cwd, slug), "#{safe}.json")
  end

  defp write_dossier!(cwd, slug, transaction_id, dossier) do
    path = dossier_path(cwd, slug, transaction_id)
    File.mkdir_p!(Path.dirname(path))

    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}"
      )

    File.write!(temporary, Jason.encode!(dossier))
    File.rename!(temporary, path)
    :ok
  rescue
    e -> {:error, "cannot write dossier: #{Exception.message(e)}"}
  end

  @doc """
  Idempotently retires an active dossier to `"completed"` after the
  deterministic post-commit-step verification (one commit, tree, gate) has
  proven the recovered bytes durably landed. Replaces
  `complete_resume_claim!/2` for the dossier-based path. A no-op (`:ok`)
  when no active dossier exists for `slug` — completion is the SOLE success
  transition; calling it twice, or on an already-`completed`/`superseded`
  dossier, is not an error.
  """
  @spec complete_transaction!(String.t(), String.t()) :: :ok
  def complete_transaction!(cwd, slug) do
    case active_dossier(cwd, slug) do
      {:ok, nil} ->
        :ok

      {:ok, dossier} ->
        completed = Map.merge(dossier, %{"stage" => "completed", "updated_at" => now()})
        :ok = write_dossier!(cwd, slug, dossier["transaction_id"], completed)
        :ok

      {:error, reason} ->
        raise "InterruptedCycleRecovery: cannot complete transaction for #{slug}: #{reason}"
    end
  end

  @doc """
  Materializes the ACTIVE dossier for `slug` (when one exists and the
  claimed pitch is genuinely ready-only) onto the current working tree via a
  checked binary-diff replay — never a branch checkout, soft-reset, or HEAD
  move. Returns:

    - `{:ok, :none}` — no active dossier for this slug; ordinary fresh-start
      cycle, nothing to do.
    - `{:ok, {disposition, dossier}}` — `disposition` is `:exact`
      (current HEAD == dossier's `source_base_sha`, replayed tree exactly
      equals `recovery_tree_sha`), `:advanced` (current HEAD descends from
      `source_base_sha` but has moved), or `:operator` (a differing dirty
      tree was itself parked onto a second `recovery/operator/<slug>/<ts>`
      ref before materializing the original recovery). The working tree now
      carries the recovered bytes dirty-and-unstaged.
    - `{:error, reason}` — missing/moved ref, wrong ancestry, conflicting
      apply, or an already-materialized dossier. The original clean
      checkout and recovery ref are left untouched.

  Scope is NEVER a reason to refuse: a dossier whose changed paths exceed
  the pitch's declared `scope:` materializes like any other, because the
  reviewer — not recovery — adjudicates scope expansion, and refusing here
  would strand finished work.
  """
  @spec materialize(String.t(), String.t()) ::
          {:ok, :none | {disposition(), map()}} | {:error, String.t()}
  def materialize(cwd, slug) do
    with {:ok, dossier} <- active_dossier(cwd, slug) do
      case dossier do
        nil ->
          {:ok, :none}

        %{"recovery_commit" => nil} ->
          {:ok, :none}

        # NOTE: there is deliberately NO scope clause here. A dossier whose
        # changed paths exceeded the pitch's declared `scope:` (any
        # `ownership` verdict, including legacy `"mismatch"` dossiers
        # written by older builds) materializes like any other — losing
        # finished, reviewed, approved bytes is strictly worse than any
        # sprawl a refusal would have prevented. The expansion is recorded
        # on the dossier and in the pitch's history, not enforced.
        %{} = d ->
          do_materialize(cwd, slug, d)
      end
    end
  end

  defp do_materialize(cwd, slug, dossier) do
    source_base = dossier["source_base_sha"]
    recovery_commit = dossier["recovery_commit"]
    recovery_tree_sha = dossier["recovery_tree_sha"]

    with {:ok, ref_exists} <- verify_recovery_ref(cwd, dossier),
         true <- ref_exists,
         {:ok, head} <- git(cwd, ["rev-parse", "HEAD"]),
         {:ok, status} <- git(cwd, ["status", "--porcelain", "--untracked-files=all"]) do
      dirty? = String.trim(status) != ""

      cond do
        dirty? and dirty_tree_matches_recovery?(cwd, recovery_tree_sha) ->
          {:error,
           "recovery for #{slug} already materialized on the current tree — refusing to apply twice (transaction #{dossier["transaction_id"]})"}

        dirty? ->
          park_and_apply_over_operator_edits(
            cwd,
            slug,
            dossier,
            source_base,
            recovery_commit,
            recovery_tree_sha,
            head
          )

        head == source_base ->
          apply_and_verify(cwd, source_base, recovery_commit, recovery_tree_sha, :exact, dossier)

        true ->
          case ancestor?(cwd, source_base, head) do
            true ->
              apply_and_verify(
                cwd,
                source_base,
                recovery_commit,
                recovery_tree_sha,
                :advanced,
                dossier
              )

            false ->
              {:error,
               "recovery for #{slug}: current HEAD #{head} does not descend from source base #{source_base} — refusing"}
          end
      end
    else
      false ->
        {:error,
         "recovery for #{slug}: recovery ref #{dossier["recovery_ref"]} is missing or moved — refusing"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_recovery_ref(cwd, dossier) do
    branch = dossier["recovery_ref"]
    recovery_commit = dossier["recovery_commit"]

    case git(cwd, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, sha} -> {:ok, sha == recovery_commit}
      {:error, _} -> {:ok, false}
    end
  end

  defp dirty_tree_matches_recovery?(cwd, recovery_tree_sha) do
    is_binary(recovery_tree_sha) and recovery_tree_sha != "" and
      write_tree_from_worktree(cwd) == recovery_tree_sha
  end

  defp write_tree_from_worktree(cwd) do
    idx = Path.join(System.tmp_dir!(), ".ohms-idx-#{System.unique_integer([:positive])}")

    try do
      with {:ok, head} <- git(cwd, ["rev-parse", "HEAD"]),
           {:ok, _} <- git_with_index(cwd, idx, ["read-tree", head]),
           {:ok, _} <- git_with_index(cwd, idx, ["add", "-A"]),
           {:ok, tree} <- git_with_index(cwd, idx, ["write-tree"]) do
        tree
      else
        _ -> nil
      end
    after
      File.rm(idx)
    end
  end

  defp git_with_index(cwd, idx, args) do
    env = [{"GIT_INDEX_FILE", idx}]

    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp apply_and_verify(
         cwd,
         source_base,
         recovery_commit,
         recovery_tree_sha,
         disposition,
         dossier
       ) do
    patch = Path.join(System.tmp_dir!(), ".ohms-patch-#{System.unique_integer([:positive])}")

    with {:ok, diff} <- git_raw_diff(cwd, source_base, recovery_commit) do
      File.write!(patch, diff)

      result =
        with {:ok, _} <- git(cwd, ["apply", "--check", patch]),
             {:ok, _} <- git(cwd, ["apply", patch]) do
          actual_tree = write_tree_from_worktree(cwd)

          if disposition == :exact and is_binary(recovery_tree_sha) and recovery_tree_sha != "" and
               actual_tree != recovery_tree_sha do
            {:error,
             "recovery for materialized tree mismatch: expected #{recovery_tree_sha}, got #{inspect(actual_tree)}"}
          else
            {:ok, {disposition, dossier}}
          end
        else
          {:error, reason} -> {:error, "recovery apply refused: #{reason}"}
        end

      File.rm(patch)
      result
    end
  end

  # A dirty tree at materialization time that is NOT already the recovered
  # bytes (checked by the caller) is an OPERATOR EDIT. Same-scope operator
  # bytes are preserved on a second named ref
  # (`recovery/operator/<slug>/<ts>`), recorded as auxiliary evidence on the
  # dossier, the checkout is cleaned, and the ORIGINAL recovery is then
  # materialized — reconciliation later sees both diffs. Operator bytes
  # OUTSIDE the pitch's declared `scope:` take exactly the same path: they
  # are preserved on the same ref, the expansion is recorded on the dossier
  # (`operator_ownership` / `operator_scope_expansion`), and the recovery
  # still materializes. Refusing here would have parked the operator's tree
  # and then withheld the recovered bytes — two sets of finished work
  # stranded to enforce a boundary the reviewer already adjudicates.
  defp park_and_apply_over_operator_edits(
         cwd,
         slug,
         dossier,
         source_base,
         recovery_commit,
         recovery_tree_sha,
         head
       ) do
    pitch_path = dossier["pitch_path"]
    operator_branch = "recovery/operator/#{slug}/#{utc_stamp()}"

    with {:ok, status} <- git(cwd, ["status", "--porcelain", "--untracked-files=all"]),
         :ok <- ensure_branch_absent(cwd, operator_branch),
         {:ok, original_ref} <- original_ref(cwd),
         {:ok, _} <- git(cwd, ["stash", "push", "--include-untracked", "-m", "operator:#{slug}"]),
         {:ok, _} <- git(cwd, ["stash", "branch", operator_branch, "stash@{0}"]),
         {:ok, _} <- git(cwd, ["add", "-A"]),
         {:ok, _} <-
           git(cwd, ["commit", "--allow-empty", "-m", "operator edits parked for #{slug}"]),
         {:ok, operator_tree_sha} <- git(cwd, ["rev-parse", "HEAD^{tree}"]),
         {:ok, _} <- git(cwd, ["checkout", original_ref]) do
      paths = porcelain_paths(status)
      {operator_verdict, operator_undeclared} = classify_scope(slug, pitch_path || "", paths)

      updated =
        Map.merge(dossier, %{
          "operator_ref" => operator_branch,
          "operator_tree_sha" => operator_tree_sha,
          "operator_ownership" => operator_verdict,
          "operator_scope_expansion" => operator_undeclared
        })

      :ok = write_dossier!(cwd, slug, dossier["transaction_id"], updated)

      if head == source_base or ancestor?(cwd, source_base, head) do
        apply_and_verify(
          cwd,
          source_base,
          recovery_commit,
          recovery_tree_sha,
          :operator,
          updated
        )
      else
        {:error,
         "recovery for #{slug}: current HEAD #{head} does not descend from source base #{source_base}"}
      end
    else
      {:error, reason} -> {:error, "could not park operator edits for #{slug}: #{reason}"}
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
end
