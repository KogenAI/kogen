Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.BuildReconcileTest do
  use Kogen.IsolatedCase, async: true

  import ExUnit.CaptureIO

  alias Kogen.Build.{FailureReport, Reconcile, Workspace}
  alias Kogen.ScriptedBuildFixture, as: Fixture
  alias Mix.Tasks.Kogen.Candidates
  alias Mix.Tasks.Kogen.Candidates.Remove, as: CandidatesRemove

  @tail Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)

  test "provider and exhausted stops persist budget_state in report and record" do
    dir = Fixture.fixture!()
    tail = @tail |> File.read!() |> Jason.decode!() |> Map.fetch!("output")

    assert {:error, message} =
             Fixture.run(dir,
               fail_first: [1],
               provider_fail: ["developer-2"],
               provider_tail: tail
             )

    assert message =~ "category: provider"
    [{id, record_path, record}] = Fixture.records!(dir)
    report = dir |> FailureReport.report_path(id) |> File.read!() |> Jason.decode!()
    attempt = List.last(record["attempts"])
    token = attempt["attempt_token"]

    state_rel =
      ".kogen/runtime/scenario-tracking/#{id}/verification/attempt-0-#{token}/state.json"

    state_bytes = File.read!(Path.join(dir, state_rel))

    expected_budget = %{
      "outer_attempt" => 0,
      "offline_retries" => 4,
      "verification_retries" => 2,
      "offline_failures" => 1,
      "failures_since_pass" => 0,
      "terminal_state" => "pending",
      "state" => state_rel,
      "state_sha256" => sha(state_bytes)
    }

    assert report["budget_state"] == expected_budget
    assert attempt["budget_state"] == expected_budget
    assert report["published"] == nil
    assert report["record_sha256"] == sha(File.read!(record_path))

    dir2 = Fixture.fixture!()
    assert {:error, exhausted} = Fixture.run(dir2, fail_all: [1])
    assert exhausted =~ "category: offline-exhausted"
    [{id2, _path2, record2}] = Fixture.records!(dir2)
    report2 = dir2 |> FailureReport.report_path(id2) |> File.read!() |> Jason.decode!()
    attempt2 = List.last(record2["attempts"])
    budget2 = report2["budget_state"]
    assert budget2 == attempt2["budget_state"]
    assert budget2["outer_attempt"] == 0
    assert budget2["offline_retries"] == 4
    assert budget2["verification_retries"] == 2
    assert budget2["offline_failures"] == 5
    assert budget2["failures_since_pass"] == 0
    assert budget2["terminal_state"] == "offline_exhausted"
    assert budget2["state_sha256"] == sha(File.read!(Path.join(dir2, budget2["state"])))
  end

  test "admission stop has null budget_state and interrupted categories count toward nothing" do
    dir = Fixture.fixture!()
    File.rm_rf!(Path.join(dir, "deps"))
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "category: admission"
    [{id, _path, _record}] = Fixture.records!(dir)
    report = dir |> FailureReport.report_path(id) |> File.read!() |> Jason.decode!()
    assert report["budget_state"] == nil
    assert report["published"] == nil
    assert FailureReport.classify("interrupted") == {"interrupted", "rebuild"}
    assert FailureReport.classify("publication-interrupted") == {"interrupted", "inspect"}
    assert FailureReport.counts_toward("interrupted") == nil
    assert FailureReport.counts_toward("publication-interrupted") == nil
  end

  test "publication interruption reports inspect or remove according to ancestry" do
    dir = Fixture.fixture!()
    id = "publication-build"
    record_path = Path.join([dir, ".kogen/runtime/scenario-tracking", id, "record.json"])
    File.mkdir_p!(Path.dirname(record_path))

    record = %{
      "intent" => %{"id" => "intent", "slug" => "scripted-build"},
      "approved_package_digest" => "pkg",
      "attempts" => [],
      "status" => "accepted"
    }

    bytes = Jason.encode!(record)
    File.write!(record_path, bytes)

    owner = %{
      "build_id" => id,
      "worktree_path" => "candidate",
      "branch" => "branch",
      "harness_home" => "harness"
    }

    assert {:ok, _} =
             FailureReport.record_interrupted(
               dir,
               owner,
               record_path,
               bytes,
               record,
               "publication-interrupted",
               "publication-interrupted: dead",
               false
             )

    report = dir |> FailureReport.report_path(id) |> File.read!() |> Jason.decode!()
    assert report["published"] == false
    assert report["next_action"] == "inspect"
    assert report["next_command"] == nil
  end

  test "reconcile reports a dead owner from its record status and is idempotent" do
    dir = Fixture.fixture!()
    build_id = "dead-build"
    project = Workspace.project_dir(dir)
    owner_dir = Path.join(project, "candidates")
    File.mkdir_p!(owner_dir)

    owner = %{
      "schema_version" => 1,
      "build_id" => build_id,
      "intent_id" => "intent",
      "slug" => "scripted-build",
      "title" => "dead",
      "control_root" => dir,
      "worktree_path" => Path.join(project, "scripted-build-#{build_id}"),
      "branch" => "kogen/scripted-build/#{build_id}",
      "admitted_branch" => "main",
      "admitted_commit" => Workspace.branch_commit(dir, "main"),
      "harness_home" => Path.join([project, "harness", build_id]),
      "credential_bindings" => [],
      "started_at" => "2026-01-01T00:00:00Z",
      "status" => "running",
      "candidate_commit" => nil
    }

    File.write!(Workspace.owner_path(dir, build_id), Jason.encode!(owner, pretty: true))
    record_path = Path.join([dir, ".kogen/runtime/scenario-tracking", build_id, "record.json"])
    File.mkdir_p!(Path.dirname(record_path))

    record = %{
      "schema_version" => 2,
      "intent" => %{"id" => "intent", "slug" => "scripted-build"},
      "approved_package_digest" => "pkg",
      "attempts" => [],
      "status" => "pending"
    }

    bytes = Jason.encode!(record, pretty: true)
    File.write!(record_path, bytes)

    assert :ok = Reconcile.run(dir)
    report_path = FailureReport.report_path(dir, build_id)
    report = File.read!(report_path) |> Jason.decode!()
    assert report["category"] == "interrupted"
    assert report["record_sha256"] == sha(bytes)

    assert Jason.decode!(File.read!(Workspace.owner_path(dir, build_id)))["status"] ==
             "stopped: interrupted"

    report_bytes = File.read!(report_path)
    assert :ok = Reconcile.run(dir)
    assert File.read!(report_path) == report_bytes
  end

  @tag timeout: 120_000
  test "a killed stand-in is reconciled by the next fixture Build" do
    dir = Fixture.fixture!()
    standin = Fixture.start_standin!(dir, fail_first: [1], hang: ["developer-2"])

    on_exit(fn ->
      System.cmd("/bin/kill", ["-9", Integer.to_string(standin.pid)], stderr_to_stdout: true)
    end)

    fake_pid = Fixture.await_hanging!(dir)
    [{dead_id, record_path, record}] = Fixture.records!(dir)
    owner_before = owner!(dir, dead_id)
    state_path = Path.join(dir, last_state_rel(record, dead_id))
    record_bytes = File.read!(record_path)
    state_bytes = File.read!(state_path)
    tree_before = tree!(owner_before["worktree_path"])
    System.cmd("/bin/kill", ["-9", Integer.to_string(standin.pid)], stderr_to_stdout: true)
    wait_gone!(standin.pid)
    wait_gone!(fake_pid)
    Fixture.add_intent!(dir, "scripted-other", "01960000-0000-7000-8000-0000000c0de3")
    output = capture_io(fn -> assert :ok = Fixture.run(dir, slug: "scripted-other") end)
    assert output =~ "Reclaimed a stale build lock"
    report = dir |> FailureReport.report_path(dead_id) |> File.read!() |> Jason.decode!()
    assert report["category"] == "interrupted"
    assert report["class"] == "interrupted"
    assert report["counts_toward"] == nil
    assert report["next_action"] == "rebuild"
    assert report["developer_session_id"] == "developer-session"
    assert report["signature"] == List.last(List.last(record["attempts"])["cycle_signatures"])
    assert report["budget_state"]["outer_attempt"] == 0
    assert report["budget_state"]["offline_retries"] == 4
    assert report["budget_state"]["verification_retries"] == 2
    assert report["budget_state"]["offline_failures"] == 1
    assert report["budget_state"]["failures_since_pass"] == 0
    assert report["budget_state"]["terminal_state"] == "pending"
    assert report["budget_state"]["state_sha256"] == sha(state_bytes)
    assert report["record_sha256"] == sha(record_bytes)
    assert report["candidate"]["worktree"] == owner_before["worktree_path"]
    assert report["candidate"]["branch"] == owner_before["branch"]
    assert report["candidate"]["harness_home"] == owner_before["harness_home"]
    assert report["candidate"]["owner_record"] == Workspace.owner_path(dir, dead_id)
    assert String.starts_with?(report["reason"], "interrupted: ")
    assert owner!(dir, dead_id)["status"] == "stopped: interrupted"
    assert File.read!(record_path) == record_bytes
    assert tree!(owner_before["worktree_path"]) == tree_before

    report_bytes = File.read!(FailureReport.report_path(dir, dead_id))
    Fixture.add_intent!(dir, "scripted-third", "01960000-0000-7000-8000-0000000c0de4")
    assert :ok = Fixture.run(dir, slug: "scripted-third")
    assert File.read!(FailureReport.report_path(dir, dead_id)) == report_bytes

    tracking_dir = Path.dirname(record_path)
    assert Path.wildcard(Path.join(tracking_dir, "failure-report.json")) |> length() == 1
    assert Path.wildcard(Path.join(tracking_dir, ".failure-report-*.tmp")) == []
  end

  @tag timeout: 120_000
  test "a first-turn kill has no Developer session and a stop signature" do
    dir = Fixture.fixture!()
    standin = Fixture.start_standin!(dir, hang: ["developer-1"])

    on_exit(fn ->
      System.cmd("/bin/kill", ["-9", Integer.to_string(standin.pid)], stderr_to_stdout: true)
    end)

    fake_pid = Fixture.await_hanging!(dir)
    [{dead_id, _record_path, _record}] = Fixture.records!(dir)
    System.cmd("/bin/kill", ["-9", Integer.to_string(standin.pid)], stderr_to_stdout: true)
    wait_gone!(standin.pid)
    wait_gone!(fake_pid)
    other!(dir, "scripted-other", "01960000-0000-7000-8000-0000000c0de3")
    report = dir |> FailureReport.report_path(dead_id) |> File.read!() |> Jason.decode!()
    assert report["developer_session_id"] == nil
    assert report["signature"]["source"] == "stop"
    assert report["budget_state"]["offline_failures"] == 0
    assert report["budget_state"]["terminal_state"] == "pending"
    assert owner!(dir, dead_id)["status"] == "stopped: interrupted"
  end

  test "an existing provider report only repairs the owner status" do
    dir = Fixture.fixture!()
    tail = @tail |> File.read!() |> Jason.decode!() |> Map.fetch!("output")

    assert {:error, _} =
             Fixture.run(dir,
               fail_first: [1],
               provider_fail: ["developer-2"],
               provider_tail: tail
             )

    [{dead_id, _record_path, _record}] = Fixture.records!(dir)
    report_path = FailureReport.report_path(dir, dead_id)
    report_bytes = File.read!(report_path)
    owner_path = Workspace.owner_path(dir, dead_id)
    owner = owner!(dir, dead_id)
    File.write!(owner_path, Jason.encode!(Map.put(owner, "status", "running"), pretty: true))
    other!(dir, "scripted-other", "01960000-0000-7000-8000-0000000c0de3")
    assert owner!(dir, dead_id)["status"] == "stopped: provider"
    assert File.read!(report_path) == report_bytes
  end

  test "a publication crash before fast-forward is inspectable and not published" do
    dir = Fixture.fixture!()
    {dead_id, _record_path, _record} = provider_stopped!(dir)
    report_path = FailureReport.report_path(dir, dead_id)
    File.rm!(report_path)
    rewrite_record_status!(dir, dead_id, "accepted")
    rewrite_owner_status!(dir, dead_id, "running")
    other!(dir, "scripted-other", "01960000-0000-7000-8000-0000000c0de3")
    report = File.read!(report_path) |> Jason.decode!()
    assert report["category"] == "publication-interrupted"
    assert report["class"] == "interrupted"
    assert report["published"] == false
    assert report["next_action"] == "inspect"
    assert report["next_command"] == nil
    assert report["counts_toward"] == nil
    assert owner!(dir, dead_id)["status"] == "stopped: publication-interrupted"
    output = capture_io(fn -> File.cd!(dir, fn -> Candidates.run([]) end) end)
    refute output =~ ~r/^\s*published: /m
  end

  @tag timeout: 120_000
  test "a published publication crash is rejected for its slug and removable after reconcile" do
    dir = Fixture.fixture!()
    {dead_id, _record_path, _record} = provider_stopped!(dir)
    report_path = FailureReport.report_path(dir, dead_id)
    File.rm!(report_path)
    rewrite_record_status!(dir, dead_id, "accepted")
    rewrite_owner_status!(dir, dead_id, "running")
    owner = owner!(dir, dead_id)
    commit = write_complete_commit!(owner["worktree_path"])
    git!(dir, ["merge", "--ff-only", commit])

    assert {:error, "Complete Intent already exists: scripted-build"} = Fixture.run(dir)
    refute File.exists?(Workspace.lock_path(dir))
    refute File.exists?(report_path)
    assert owner!(dir, dead_id)["status"] == "running"

    output = capture_io(fn -> File.cd!(dir, fn -> Candidates.run([]) end) end)

    assert output =~
             "  published: #{commit} is on main; remove it with mix kogen.candidates.remove #{dead_id}"

    assert output =~ "report:   none"

    other!(dir, "scripted-other", "01960000-0000-7000-8000-0000000c0de3")
    report = File.read!(report_path) |> Jason.decode!()
    assert report["published"] == true
    assert report["next_action"] == "remove"
    assert report["next_command"] == "mix kogen.candidates.remove #{dead_id}"
    assert owner!(dir, dead_id)["status"] == "stopped: publication-interrupted"

    output = capture_io(fn -> File.cd!(dir, fn -> Candidates.run([]) end) end)
    assert output =~ "class:   interrupted"
    assert output =~ "next:    remove (mix kogen.candidates.remove #{dead_id})"
    capture_io(fn -> File.cd!(dir, fn -> CandidatesRemove.run([dead_id]) end) end)
    refute File.exists?(owner["worktree_path"])
    refute File.exists?(Workspace.owner_path(dir, dead_id))
  end

  defp other!(dir, slug, id) do
    Fixture.add_intent!(dir, slug, id)
    assert :ok = Fixture.run(dir, slug: slug)
  end

  defp provider_stopped!(dir) do
    tail = @tail |> File.read!() |> Jason.decode!() |> Map.fetch!("output")

    assert {:error, message} =
             Fixture.run(dir,
               fail_first: [1],
               provider_fail: ["developer-2"],
               provider_tail: tail
             )

    assert message =~ "category: provider"
    [{id, path, record}] = Fixture.records!(dir)
    {id, path, record}
  end

  defp rewrite_record_status!(dir, id, status) do
    path = dir |> Path.join(".kogen/runtime/scenario-tracking/#{id}/record.json")
    record = path |> File.read!() |> Jason.decode!() |> Map.put("status", status)
    File.write!(path, Jason.encode!(record, pretty: true))
  end

  defp rewrite_owner_status!(dir, id, status) do
    path = Workspace.owner_path(dir, id)
    owner = path |> File.read!() |> Jason.decode!() |> Map.put("status", status)
    File.write!(path, Jason.encode!(owner, pretty: true))
  end

  defp write_complete_commit!(worktree) do
    path = Path.join([worktree, ".kogen/intents/complete/scripted-build/INTENT.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# fabricated\n")
    git!(worktree, ["add", "-A"])
    git!(worktree, ["commit", "-q", "-m", "fabricated"], git_env())
    git!(worktree, ["rev-parse", "HEAD"])
  end

  defp git!(dir, args, env \\ []) do
    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> flunk("git #{inspect(args)} failed (#{status}): #{out}")
    end
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]
  end

  defp owner!(dir, id), do: Workspace.owner_path(dir, id) |> File.read!() |> Jason.decode!()

  defp last_state_rel(record, id) do
    attempt = List.last(record["attempts"])

    ".kogen/runtime/scenario-tracking/#{id}/verification/attempt-#{attempt["number"]}-#{attempt["attempt_token"]}/state.json"
  end

  defp tree!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&(String.contains?(&1, "/.git/") or &1 == Path.join(root, ".git")))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, root), sha(File.read!(path))} end)
  end

  defp wait_gone!(pid, deadline \\ System.monotonic_time(:millisecond) + 20_000) do
    alive? =
      match?(
        {_out, 0},
        System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
      )

    if alive? and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      wait_gone!(pid, deadline)
    else
      refute alive?, "process #{pid} remained alive"
    end
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
