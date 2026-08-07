defmodule CodegenTestHarness.InterruptedCycleRecoveryTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.InterruptedCycleRecovery
  alias CodegenTestHarness.OrchestrationLoop
  alias Mix.Tasks.Codegen.Loop

  setup do
    cwd =
      Path.join(System.tmp_dir!(), "interrupted-recovery-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  test "returns none when no pitch is claimed", %{cwd: cwd} do
    assert {:ok, :none} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])
  end

  test "resumes a ready claim from a persisted recovery journal", %{cwd: cwd} do
    init_repo!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    File.write!(Path.join(cwd, "tracked.txt"), "recovered work\n")
    ready = ready_pitch(cwd, "stranded")
    File.mkdir_p!(Path.dirname(ready))
    File.write!(ready, "---\nstatus: SHAPED\n---\n# stranded\n")
    write_journal!(cwd, "stranded", "", "resume_pending")

    assert {:ok, {:resume, "stranded"}} =
             InterruptedCycleRecovery.reconcile(
               cwd: cwd,
               roles: ["developer-phoenix-backend", "reviewer-phoenix"],
               cycle_state_get_fn: fn _ -> "GATED" end,
               cycle_state_slug_fn: fn _ -> "stranded" end,
               read_verdict_fn: fn _ -> :clear end,
               gate_tree_match_fn: fn _ -> true end,
               gate_result_base_sha_fn: fn _ -> git_head!(cwd) end
             )
  end

  test "halts when a recovery journal has no matching building or ready claim", %{cwd: cwd} do
    write_journal!(cwd, "stranded", "", "resume_pending")

    assert {:error, reason} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])

    assert reason =~ "no ready claim"
  end

  test "rejects a journal with an out-of-range stage as malformed, never a raw crash", %{cwd: cwd} do
    init_repo!(cwd)
    claim = building_pitch!(cwd, "stranded")
    journal = journal_path(cwd)
    File.mkdir_p!(Path.dirname(journal))

    File.write!(
      journal,
      Jason.encode!(%{
        "branch" => "",
        "original_ref" => "master",
        "slug" => "stranded",
        "stage" => "unexpected_stage",
        "transaction_id" => "interrupted-recovery-test",
        "updated_at" => "2026-07-22T00:00:00Z"
      })
    )

    assert {:error, reason} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])

    assert reason =~ "malformed journal fields"
    assert File.exists?(claim)
  end

  test "rejects malformed recovery journal without moving the claim", %{cwd: cwd} do
    claim = building_pitch!(cwd, "stranded")
    journal = Path.join([cwd, "codegen", "gate-pending", "interrupted-recovery.json"])
    File.mkdir_p!(Path.dirname(journal))
    File.write!(journal, "not JSON")

    assert {:error, reason} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])

    assert reason =~ "malformed JSON"
    assert File.exists?(claim)
  end

  test "moves a valid checkpoint claim back to ready and clears journal when resumed", %{cwd: cwd} do
    init_repo!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    File.write!(Path.join(cwd, "tracked.txt"), "recovered work\n")
    claim = building_pitch!(cwd, "stranded")
    write_journal!(cwd, "stranded", "", "resume_pending")

    assert {:ok, {:resume, "stranded"}} =
             InterruptedCycleRecovery.reconcile(
               cwd: cwd,
               roles: ["developer-phoenix-backend", "reviewer-phoenix"],
               cycle_state_get_fn: fn _ -> "GATED" end,
               cycle_state_slug_fn: fn _ -> "stranded" end,
               read_verdict_fn: fn _ -> :clear end,
               gate_tree_match_fn: fn _ -> true end,
               gate_result_base_sha_fn: fn _ -> git_head!(cwd) end
             )

    refute File.exists?(claim)
    assert File.exists?(ready_pitch(cwd, "stranded"))
    assert File.exists?(journal_path(cwd))

    assert :ok = InterruptedCycleRecovery.complete_resume_claim!(cwd, "stranded")
    refute File.exists?(journal_path(cwd))
  end

  test "stale resume pending checkpoint is cleared and requeued for a full run", %{cwd: cwd} do
    init_repo!(cwd)
    claim = building_pitch!(cwd, "stranded")
    write_journal!(cwd, "stranded", "", "resume_pending")

    assert {:ok, {:requeued, "stranded", :clean}} =
             InterruptedCycleRecovery.reconcile(
               cwd: cwd,
               roles: ["developer-phoenix-backend"],
               cycle_state_get_fn: fn _ -> "" end
             )

    refute File.exists?(claim)
    assert File.exists?(ready_pitch(cwd, "stranded"))
    refute File.exists?(journal_path(cwd))
  end

  test "clean ignored checkpoint and building claim requeue without a recovery loop", %{cwd: cwd} do
    init_repo!(cwd)
    File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    claim = building_pitch!(cwd, "stranded")
    write_journal!(cwd, "stranded", "", "resume_pending")
    write_checkpoint!(cwd)

    assert git_status!(cwd) == ""

    assert {:ok, {:requeued, "stranded", :clean}} =
             InterruptedCycleRecovery.reconcile(
               cwd: cwd,
               roles: ["reviewer-phoenix"],
               cycle_state_get_fn: fn _ -> "GATED" end,
               cycle_state_slug_fn: fn _ -> "stranded" end,
               read_verdict_fn: fn _ -> :clear end,
               gate_tree_match_fn: fn _ -> true end,
               gate_result_base_sha_fn: fn _ -> git_head!(cwd) end
             )

    refute File.exists?(claim)
    assert File.exists?(ready_pitch(cwd, "stranded"))
    refute File.exists?(journal_path(cwd))
    refute File.exists?(Path.join([cwd, "codegen", "gate-pending", "gate-result.json"]))
    refute File.exists?(Path.join([cwd, "codegen", "gate-pending", "cycle-state.json"]))
  end

  test "already-landed descendant commit survives clean checkpoint requeue", %{cwd: cwd} do
    init_repo!(cwd)
    File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    base_head = git_head!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "recovered and landed\n")
    commit!(cwd, "land recovered work")
    landed_head = git_head!(cwd)
    building_pitch!(cwd, "stranded")
    write_journal!(cwd, "stranded", "", "resume_pending")

    assert {:ok, {:requeued, "stranded", :clean}} =
             InterruptedCycleRecovery.reconcile(
               cwd: cwd,
               roles: ["reviewer-phoenix"],
               cycle_state_get_fn: fn _ -> "GATED" end,
               cycle_state_slug_fn: fn _ -> "stranded" end,
               read_verdict_fn: fn _ -> :clear end,
               gate_tree_match_fn: fn _ -> true end,
               gate_result_base_sha_fn: fn _ -> base_head end
             )

    assert git_head!(cwd) == landed_head
    assert git_status!(cwd) == ""
    assert File.exists?(ready_pitch(cwd, "stranded"))
    refute File.exists?(journal_path(cwd))
  end

  test "persisted ready claim survives clean requeue and remains claimable by the direct loop", %{
    cwd: cwd
  } do
    init_repo!(cwd)
    File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    base_head = git_head!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "recovered and landed\n")
    commit!(cwd, "land recovered work")
    landed_head = git_head!(cwd)
    ready = ready_pitch(cwd, "stranded")
    File.mkdir_p!(Path.dirname(ready))
    File.write!(ready, "---\nstatus: SHAPED\n---\n# stranded\n")
    write_journal!(cwd, "stranded", "", "resume_pending")

    recovery =
      InterruptedCycleRecovery.reconcile(
        cwd: cwd,
        roles: ["reviewer-phoenix"],
        cycle_state_get_fn: fn _ -> "GATED" end,
        cycle_state_slug_fn: fn _ -> "stranded" end,
        read_verdict_fn: fn _ -> :clear end,
        gate_tree_match_fn: fn _ -> true end,
        gate_result_base_sha_fn: fn _ -> base_head end
      )

    assert recovery == {:ok, {:requeued, "stranded", :clean}}
    assert File.exists?(ready)
    assert git_head!(cwd) == landed_head
    assert git_status!(cwd) == ""

    assert :ok =
             Loop.route_reconcile_result(recovery, "stranded", fn ->
               assert File.exists?(ready)
               :ok
             end)
  end

  test "replays parked journal after crash without a second parking branch", %{cwd: cwd} do
    init_repo!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    claim = building_pitch!(cwd, "stranded")
    branch = "recovery/interrupted/stranded/replayed"
    transaction_id = "interrupted-recovery-test-replay"
    create_parked_branch!(cwd, branch, transaction_id)
    write_journal!(cwd, "stranded", branch, "parked", transaction_id)

    assert {:ok, {:requeued, "stranded", {:parked, ^branch}}} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])

    refute File.exists?(claim)
    assert File.exists?(ready_pitch(cwd, "stranded"))
    refute File.exists?(journal_path(cwd))

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               cwd,
               "show-ref",
               "--verify",
               "--quiet",
               "refs/heads/#{branch}"
             ])
  end

  test "adopts only a parking stash with matching transaction identity", %{cwd: cwd} do
    init_repo!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "base\n")
    commit!(cwd, "base")
    claim = building_pitch!(cwd, "stranded")
    transaction_id = "interrupted-recovery-test-stash"
    File.write!(Path.join(cwd, "tracked.txt"), "parked\n")
    assert {_, 0} = System.cmd("git", ["-C", cwd, "stash", "push", "-m", transaction_id])
    write_journal!(cwd, "stranded", "", "parking", transaction_id)

    assert {:ok, {:requeued, "stranded", {:parked, branch}}} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])

    assert {"parked\n", 0} = System.cmd("git", ["-C", cwd, "show", "#{branch}:tracked.txt"])
    refute File.exists?(journal_path(cwd))
    refute File.exists?(claim)
  end

  test "halts parking recovery when stash identity does not match", %{cwd: cwd} do
    init_repo!(cwd)
    claim = building_pitch!(cwd, "stranded")
    write_journal!(cwd, "stranded", "", "parking", "expected-transaction")

    assert {:error, reason} =
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["developer-phoenix-backend"])

    assert reason =~ "no matching stash or branch"
    assert File.exists?(claim)
  end

  test "parks tracked and untracked work on a recovery branch before requeueing", %{cwd: cwd} do
    init_repo!(cwd)
    tracked = Path.join(cwd, "tracked.txt")
    File.write!(tracked, "base\n")
    commit!(cwd, "base")
    claim = building_pitch!(cwd, "stranded")
    File.write!(tracked, "changed\n")
    File.write!(Path.join(cwd, "untracked.txt"), "preserve\n")

    assert {:ok, {:requeued, "stranded", {:parked, branch}}} =
             InterruptedCycleRecovery.reconcile(
               cwd: cwd,
               roles: ["developer-phoenix-backend"],
               cycle_state_get_fn: fn _ -> "" end
             )

    refute File.exists?(claim)
    requeued = Path.join([cwd, "codegen", "pitches", "ready", "stranded.md"])
    assert File.exists?(requeued)
    assert {_, 0} = System.cmd("git", ["-C", cwd, "diff", "--quiet"])
    assert {"changed\n", 0} = System.cmd("git", ["-C", cwd, "show", "#{branch}:tracked.txt"])
    assert {"preserve\n", 0} = System.cmd("git", ["-C", cwd, "show", "#{branch}:untracked.txt"])

    # The requeued pitch carries a Build failure history row naming who must
    # look at it next. There is no planner to hand an interrupted cycle back
    # to any more — the row names the operator.
    history = File.read!(requeued)
    assert history =~ "| interrupted recovery |"
    assert history =~ "next=operator-inspection-required"
    refute history =~ "planner"
  end

  describe "resume_role_for_recovery/3" do
    @phoenix_roles ~w(developer-phoenix-backend reviewer-phoenix context-curator)
    @static_roles ~w(developer-static reviewer-static context-curator)

    test ":advanced always reconciles at the stack's developer, on both stacks" do
      assert OrchestrationLoop.resume_role_for_recovery(:advanced, "GATED", @phoenix_roles) ==
               "developer-phoenix-backend"

      assert OrchestrationLoop.resume_role_for_recovery(:advanced, "REVIEWED", @static_roles) ==
               "developer-static"
    end

    test ":operator always reconciles at the stack's developer, on both stacks" do
      assert OrchestrationLoop.resume_role_for_recovery(:operator, "CURATED", @phoenix_roles) ==
               "developer-phoenix-backend"

      assert OrchestrationLoop.resume_role_for_recovery(:operator, nil, @static_roles) ==
               "developer-static"
    end

    test "the recorded cycle_state cannot pull a moved-base resume past the developer" do
      # Every cycle_state a dossier can carry — the developer is the answer
      # for all of them once the base has moved.
      for state <- ["GATED", "REVIEWED", "CURATED", nil, ""] do
        assert OrchestrationLoop.resume_role_for_recovery(:advanced, state, @phoenix_roles) ==
                 "developer-phoenix-backend"
      end
    end

    test ":exact still honours the recorded cycle_state (unchanged)" do
      assert OrchestrationLoop.resume_role_for_recovery(:exact, "GATED", @phoenix_roles) ==
               "reviewer-phoenix"
    end
  end

  # ── Per-transaction recovery dossiers (park_failure/1, materialize/2) ──────
  # See pitch "restarted builds resume owned work".

  describe "park_failure/1 + materialize/2 — dossier subsystem" do
    test "parks tracked + untracked bytes, records a ready dossier, clean checkout", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt, blob.bin")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")

      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")
      File.write!(Path.join(cwd, "blob.bin"), <<0, 1, 255>>)

      assert {:ok, dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert dossier["stage"] == "ready"
      assert dossier["ownership"] == "ok"
      assert dossier["schema_version"] == 1
      assert git_status!(cwd) == ""
      assert {"base\n", 0} = System.cmd("git", ["-C", cwd, "show", "HEAD:tracked.txt"])
    end

    test "scope expansion parks bytes, REPORTS the undeclared paths, and still materializes", %{
      cwd: cwd
    } do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")

      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")
      File.write!(Path.join(cwd, "unrelated.txt"), "beyond declared scope\n")

      assert {:ok, dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      # Reported, not enforced: verdict + the exact undeclared paths.
      assert dossier["ownership"] == "expanded"
      assert dossier["scope_expansion"] == ["unrelated.txt"]
      assert File.read!(pitch_path) =~ "scope_expansion=unrelated.txt"

      # ...and the work is restored anyway, byte-identical to what was parked.
      assert {:ok, {:exact, materialized}} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"
      assert File.read!(Path.join(cwd, "unrelated.txt")) == "beyond declared scope\n"
      assert worktree_tree_sha!(cwd) == materialized["recovery_tree_sha"]
    end

    test "an unparseable pitch records ownership unknown and still materializes", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      # `scope:` present but not a `[...]` flow list — `parse_scope/2` raises.
      # Historically `classify_scope/3`'s bare rescue turned that into
      # "mismatch", which stranded the work behind a parse bug.
      File.write!(pitch_path, "---\nscope: tracked.txt\n---\n# probe\n")

      assert {:ok, dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert dossier["ownership"] == "unknown"

      assert {:ok, {:exact, materialized}} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"
      assert worktree_tree_sha!(cwd) == materialized["recovery_tree_sha"]
    end

    test "a legacy dossier tagged ownership mismatch still materializes", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      # Rewrite the on-disk dossier the way an older build would have.
      [dossier_file] =
        Path.wildcard(
          Path.join([cwd, "codegen", "gate-pending", "recoveries", "probe", "*.json"])
        )

      File.write!(dossier_file, Jason.encode!(Map.put(dossier, "ownership", "mismatch")))

      assert {:ok, {:exact, materialized}} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"
      assert worktree_tree_sha!(cwd) == materialized["recovery_tree_sha"]
    end

    test "materialize/2: exact-base disposition replays byte-identical tree", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert {:ok, {:exact, _dossier}} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"
      assert git_status!(cwd) != ""
    end

    test "materialize/2: advanced-base disposition preserves intervening commits", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      File.write!(Path.join(cwd, "later.txt"), "later\n")
      commit!(cwd, "later")

      assert {:ok, {:advanced, _dossier}} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"
      assert File.exists?(Path.join(cwd, "later.txt"))
    end

    test "materialize/2: conflicting apply refuses non-zero, clean checkout, ref untouched", %{
      cwd: cwd
    } do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      File.write!(Path.join(cwd, "tracked.txt"), "conflict\n")
      commit!(cwd, "conflict")
      conflict_head = git_head!(cwd)

      assert {:error, reason} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert reason =~ "apply check refused"
      assert git_head!(cwd) == conflict_head
      assert git_status!(cwd) == ""
    end

    test "incompatible replay is durably quarantined without a second apply attempt", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "recovered\n")

      assert {:ok, parked} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      File.write!(Path.join(cwd, "tracked.txt"), "conflict\n")
      commit!(cwd, "conflict")
      head = git_head!(cwd)

      assert {:error, first_reason} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert first_reason =~ "requires reconciliation"

      assert {:ok, quarantined} = InterruptedCycleRecovery.active_dossier(cwd, "probe")
      assert quarantined["stage"] == "reconciliation_required"
      assert quarantined["reconciliation_head"] == head
      assert quarantined["reconciliation_reason"] =~ "apply check refused"
      assert quarantined["reconciliation_paths"] == ["tracked.txt"]
      assert quarantined["recovery_ref"] == parked["recovery_ref"]
      assert git_status!(cwd) == ""

      # The durable state is authoritative: later startup reads it without
      # another replay attempt or any mutation of the dossier/ref/worktree.
      assert {:error, second_reason} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert second_reason == first_reason
      assert {:ok, ^quarantined} = InterruptedCycleRecovery.active_dossier(cwd, "probe")
      assert git_status!(cwd) == ""
    end

    test "materialize/2: same-scope operator edit is parked on a second ref, then original applies",
         %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt, other.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      File.write!(Path.join(cwd, "other.txt"), "operator edit\n")

      assert {:ok, {:operator, dossier}} = InterruptedCycleRecovery.materialize(cwd, "probe")
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"
      assert is_binary(dossier["operator_ref"])

      assert {_, 0} =
               System.cmd("git", [
                 "-C",
                 cwd,
                 "show-ref",
                 "--verify",
                 "--quiet",
                 "refs/heads/#{dossier["operator_ref"]}"
               ])
    end

    test "materialize/2: an operator edit beyond scope is preserved AND the recovery applies",
         %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      File.write!(Path.join(cwd, "unrelated.txt"), "operator beyond scope\n")

      assert {:ok, {:operator, dossier}} = InterruptedCycleRecovery.materialize(cwd, "probe")

      # The recovered bytes land...
      assert File.read!(Path.join(cwd, "tracked.txt")) == "changed\n"

      # ...the operator's own bytes survive on their named ref...
      assert is_binary(dossier["operator_ref"])

      assert {"operator beyond scope\n", 0} =
               System.cmd("git", [
                 "-C",
                 cwd,
                 "show",
                 "#{dossier["operator_ref"]}:unrelated.txt"
               ])

      # ...and the expansion is REPORTED on the dossier rather than enforced.
      assert dossier["operator_ownership"] == "expanded"
      assert dossier["operator_scope_expansion"] == ["unrelated.txt"]
    end

    test "successor transaction: a second failure supersedes the predecessor dossier", %{
      cwd: cwd
    } do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "first failure\n")

      assert {:ok, first} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "first"
               )

      File.write!(Path.join(cwd, "tracked.txt"), "second failure\n")

      assert {:ok, second} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "second"
               )

      assert first["transaction_id"] != second["transaction_id"]
      assert {:ok, active} = InterruptedCycleRecovery.active_dossier(cwd, "probe")
      assert active["transaction_id"] == second["transaction_id"]

      # The predecessor ref must never move — still resolvable, still
      # carrying the FIRST failure's own recovered bytes.
      assert {"first failure\n", 0} =
               System.cmd("git", ["-C", cwd, "show", "#{first["recovery_commit"]}:tracked.txt"])
    end

    test "complete_transaction!/2 retires the active dossier idempotently", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert :ok = InterruptedCycleRecovery.complete_transaction!(cwd, "probe")
      assert {:ok, nil} = InterruptedCycleRecovery.active_dossier(cwd, "probe")
      # A second call on an already-completed dossier is a legal no-op.
      assert :ok = InterruptedCycleRecovery.complete_transaction!(cwd, "probe")
    end

    test "complete_transaction!/2 with no active dossier is a no-op", %{cwd: cwd} do
      assert :ok = InterruptedCycleRecovery.complete_transaction!(cwd, "never-failed")
    end

    test "park_failure/1 does not choke on a gitignored codegen/ dir (regression)", %{cwd: cwd} do
      # Regression for defect #1: an explicit `.` pathspec on `git stash
      # push` flips it into add-like semantics, which REFUSES on the
      # repo's own gitignored codegen/ ("The following paths are ignored").
      # park_failure/1 must use a bare, pathspec-free stash push.
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert dossier["stage"] == "ready"
      assert git_status!(cwd) == ""
    end

    test "park_failure/1 fail-closed: multiple active dossiers refuse rather than guessing", %{
      cwd: cwd
    } do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      assert {:ok, dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      # Hand-craft a second "active" dossier alongside the first — the same
      # malformed state `refuse_if_active_dossier/2` must catch rather than
      # silently superseding an ambiguous set.
      dir = Path.join([cwd, "codegen", "gate-pending", "recoveries", "probe"])
      rogue = Map.put(dossier, "transaction_id", "rogue-transaction")
      File.write!(Path.join(dir, "rogue.json"), Jason.encode!(rogue))

      File.write!(Path.join(cwd, "tracked.txt"), "third failure\n")

      assert {:error, reason} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "test"
               )

      assert reason =~ "multiple active recovery dossiers"
    end

    test "park_failure/1 clears a stale checkpoint before a recovery can resume", %{cwd: cwd} do
      init_repo!(cwd)
      File.write!(Path.join(cwd, ".gitignore"), "codegen/\n")
      pitch_path = seeded_pitch!(cwd, "probe", "tracked.txt")
      File.write!(Path.join(cwd, "tracked.txt"), "base\n")
      commit!(cwd, "base")
      base_head = git_head!(cwd)
      File.write!(Path.join(cwd, "tracked.txt"), "changed\n")

      pending = Path.join([cwd, "codegen", "gate-pending"])
      File.mkdir_p!(pending)
      {_add_out, 0} = System.cmd("git", ["-C", cwd, "add", "-A"])
      {tree_out, 0} = System.cmd("git", ["-C", cwd, "write-tree"])

      File.write!(
        Path.join(pending, "gate-result.json"),
        Jason.encode!(%{
          "verdict" => "clear",
          "graded_tree_sha" => String.trim(tree_out),
          "base_sha" => base_head
        })
      )

      File.write!(
        Path.join(pending, "cycle-state.json"),
        Jason.encode!(%{"state" => "GATED", "slug" => "probe"})
      )

      roles = ["developer-phoenix-backend", "reviewer-phoenix", "context-curator"]

      resume_opts = [
        cycle_state_get_fn: fn _ -> "GATED" end,
        cycle_state_slug_fn: fn _ -> "probe" end,
        read_verdict_fn: fn _ -> :clear end,
        gate_tree_match_fn: fn _ -> true end,
        gate_result_base_sha_fn: fn _ -> base_head end,
        slug: "probe"
      ]

      assert {:resume, "reviewer-phoenix", "GATED"} =
               OrchestrationLoop.resume_checkpoint(cwd, roles, resume_opts)

      assert {:ok, _dossier} =
               InterruptedCycleRecovery.park_failure(
                 cwd: cwd,
                 pitch_path: pitch_path,
                 slug: "probe",
                 namespace: "recovery/interrupted",
                 cause: "gate died mid-cycle"
               )

      refute File.exists?(Path.join(pending, "gate-result.json"))
      refute File.exists?(Path.join(pending, "cycle-state.json"))
      assert :full = OrchestrationLoop.resume_checkpoint(cwd, roles, resume_opts)
    end
  end

  # Tree sha of the working tree as-is (HEAD + every dirty/untracked path),
  # computed against a throwaway index so the repo's own index is untouched
  # — the comparison target for "the restored tree matches recovery_tree_sha".
  defp worktree_tree_sha!(cwd) do
    idx = Path.join(System.tmp_dir!(), "recovery-test-idx-#{System.unique_integer([:positive])}")
    env = [{"GIT_INDEX_FILE", idx}]

    try do
      {head, 0} = System.cmd("git", ["-C", cwd, "rev-parse", "HEAD"])
      {_, 0} = System.cmd("git", ["-C", cwd, "read-tree", String.trim(head)], env: env)
      {_, 0} = System.cmd("git", ["-C", cwd, "add", "-A"], env: env)
      {tree, 0} = System.cmd("git", ["-C", cwd, "write-tree"], env: env)
      String.trim(tree)
    after
      File.rm(idx)
    end
  end

  defp seeded_pitch!(cwd, slug, scope) do
    path = Path.join([cwd, "codegen", "pitches", "ready", "#{slug}.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nscope: [#{scope}]\n---\n# #{slug}\n")
    path
  end

  defp building_pitch!(cwd, slug) do
    path = Path.join([cwd, "codegen", "pitches", "building", "#{slug}.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nstatus: SHAPED\n---\n# #{slug}\n")
    path
  end

  defp ready_pitch(cwd, slug), do: Path.join([cwd, "codegen", "pitches", "ready", "#{slug}.md"])

  defp journal_path(cwd),
    do: Path.join([cwd, "codegen", "gate-pending", "interrupted-recovery.json"])

  defp write_checkpoint!(cwd) do
    pending = Path.join([cwd, "codegen", "gate-pending"])
    File.mkdir_p!(pending)
    File.write!(Path.join(pending, "gate-result.json"), "{}")
    File.write!(Path.join(pending, "cycle-state.json"), "{}")
  end

  defp git_status!(cwd) do
    {status, 0} = System.cmd("git", ["-C", cwd, "status", "--porcelain"])
    String.trim(status)
  end

  defp write_journal!(cwd, slug, branch, stage, transaction_id \\ "interrupted-recovery-test") do
    path = journal_path(cwd)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "branch" => branch,
        "original_ref" => default_branch!(cwd),
        "slug" => slug,
        "stage" => stage,
        "transaction_id" => transaction_id,
        "updated_at" => "2026-07-22T00:00:00Z"
      })
    )
  end

  defp create_parked_branch!(cwd, branch, transaction_id) do
    original = default_branch!(cwd)
    assert {_, 0} = System.cmd("git", ["-C", cwd, "checkout", "-qb", branch])

    assert {_, 0} =
             System.cmd("git", ["-C", cwd, "commit", "--allow-empty", "-qm", transaction_id])

    assert {_, 0} = System.cmd("git", ["-C", cwd, "checkout", "-q", original])
  end

  defp default_branch!(cwd) do
    case System.cmd("git", ["-C", cwd, "symbolic-ref", "--short", "HEAD"], stderr_to_stdout: true) do
      {ref, 0} -> String.trim(ref)
      {_output, _status} -> "master"
    end
  end

  defp git_head!(cwd) do
    {head, 0} = System.cmd("git", ["-C", cwd, "rev-parse", "HEAD"])
    String.trim(head)
  end

  defp init_repo!(cwd) do
    File.mkdir_p!(cwd)
    assert {_, 0} = System.cmd("git", ["-C", cwd, "init", "-q"])
    assert {_, 0} = System.cmd("git", ["-C", cwd, "config", "user.email", "test@example.com"])
    assert {_, 0} = System.cmd("git", ["-C", cwd, "config", "user.name", "test"])
  end

  defp commit!(cwd, subject) do
    assert {_, 0} = System.cmd("git", ["-C", cwd, "add", "-A"])
    assert {_, 0} = System.cmd("git", ["-C", cwd, "commit", "-qm", subject])
  end
end
