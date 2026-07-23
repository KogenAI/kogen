defmodule CodegenTestHarness.InterruptedCycleRecoveryTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.InterruptedCycleRecovery
  alias Mix.Tasks.Codegen.Loop

  setup do
    cwd = Path.join(System.tmp_dir!(), "interrupted-recovery-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  test "returns none when no pitch is claimed", %{cwd: cwd} do
    assert {:ok, :none} = InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])
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
               roles: ["planner-phoenix", "reviewer-phoenix"],
               cycle_state_get_fn: fn _ -> "GATED" end,
               cycle_state_slug_fn: fn _ -> "stranded" end,
               read_verdict_fn: fn _ -> :clear end,
               gate_tree_match_fn: fn _ -> true end,
               gate_result_base_sha_fn: fn _ -> git_head!(cwd) end
             )
  end

  test "halts when a recovery journal has no matching building or ready claim", %{cwd: cwd} do
    write_journal!(cwd, "stranded", "", "resume_pending")

    assert {:error, reason} = InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])
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

    assert {:error, reason} = InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])
    assert reason =~ "malformed journal fields"
    assert File.exists?(claim)
  end

  test "rejects malformed recovery journal without moving the claim", %{cwd: cwd} do
    claim = building_pitch!(cwd, "stranded")
    journal = Path.join([cwd, "codegen", "gate-pending", "interrupted-recovery.json"])
    File.mkdir_p!(Path.dirname(journal))
    File.write!(journal, "not JSON")

    assert {:error, reason} = InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])
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
               roles: ["planner-phoenix", "reviewer-phoenix"],
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
               roles: ["planner-phoenix"],
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
    assert :ok = Loop.route_reconcile_result(recovery, "stranded", fn ->
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
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])

    refute File.exists?(claim)
    assert File.exists?(ready_pitch(cwd, "stranded"))
    refute File.exists?(journal_path(cwd))
    assert {_, 0} = System.cmd("git", ["-C", cwd, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"])
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
             InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])

    assert {"parked\n", 0} = System.cmd("git", ["-C", cwd, "show", "#{branch}:tracked.txt"])
    refute File.exists?(journal_path(cwd))
    refute File.exists?(claim)
  end

  test "halts parking recovery when stash identity does not match", %{cwd: cwd} do
    init_repo!(cwd)
    claim = building_pitch!(cwd, "stranded")
    write_journal!(cwd, "stranded", "", "parking", "expected-transaction")

    assert {:error, reason} = InterruptedCycleRecovery.reconcile(cwd: cwd, roles: ["planner-phoenix"])
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
               roles: ["planner-phoenix"],
               cycle_state_get_fn: fn _ -> "" end
             )

    refute File.exists?(claim)
    assert File.exists?(Path.join([cwd, "codegen", "pitches", "ready", "stranded.md"]))
    assert {_, 0} = System.cmd("git", ["-C", cwd, "diff", "--quiet"])
    assert {"changed\n", 0} = System.cmd("git", ["-C", cwd, "show", "#{branch}:tracked.txt"])
    assert {"preserve\n", 0} = System.cmd("git", ["-C", cwd, "show", "#{branch}:untracked.txt"])
  end

  defp building_pitch!(cwd, slug) do
    path = Path.join([cwd, "codegen", "pitches", "building", "#{slug}.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nstatus: SHAPED\n---\n# #{slug}\n")
    path
  end

  defp ready_pitch(cwd, slug), do: Path.join([cwd, "codegen", "pitches", "ready", "#{slug}.md"])

  defp journal_path(cwd), do: Path.join([cwd, "codegen", "gate-pending", "interrupted-recovery.json"])

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
    assert {_, 0} = System.cmd("git", ["-C", cwd, "commit", "--allow-empty", "-qm", transaction_id])
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
