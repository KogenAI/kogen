defmodule Kogen.BuildContinuationTest do
  Code.require_file("../support/scripted_build_fixture.ex", __DIR__)
  use Kogen.IsolatedCase, async: true
  import ExUnit.CaptureIO

  alias Kogen.Build.{FailureHandoff, FailureReport, Workspace}
  alias Kogen.ScriptedBuildFixture, as: Fixture
  alias Mix.Tasks.Kogen.Candidates

  @moduletag timeout: 600_000

  test "provider stop is continued on the kept Candidate" do
    dir = Fixture.fixture!()

    tail =
      Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("output")

    assert {:error, message} =
             Fixture.run(dir,
               fail_first: [1],
               provider_fail: ["developer-2"],
               provider_tail: tail
             )

    assert message =~ "category: provider"
    [{old_id, old_path, old_record}] = Fixture.records!(dir)
    old_report_path = FailureReport.report_path(dir, old_id)
    old_report_bytes = File.read!(old_report_path)
    old_record_bytes = File.read!(old_path)
    old_report = Jason.decode!(old_report_bytes)
    assert old_report["continuable"] == true
    assert old_report["continues"] == nil
    assert old_report["next_action"] == "provider_wait"
    assert old_report["developer_session_id"] == "developer-session"
    assert old_record["route"]["name"] == "codex"
    assert List.last(old_record["attempts"])["developer_session_id"] == "developer-session"

    assert :ok =
             Fixture.run(dir,
               edits: %{
                 2 =>
                   "cat '#{Path.join(dir, ".kogen/build.lock")}' > \"$KOGEN_HARNESS_HOME/lock-seen.json\""
               }
             )

    records = Fixture.records!(dir)
    assert length(records) == 2

    {^old_id, ^old_path, ^old_record} =
      Enum.find(records, fn {id, _path, _record} -> id == old_id end)

    {new_id, new_path, new} =
      Enum.find(records, fn {_id, _path, record} -> is_map(record["continues"]) end)

    assert new["continues"] == %{
             "build_id" => old_id,
             "record_sha256" => old_report["record_sha256"],
             "category" => "provider"
           }

    assert new["status"] == "accepted"
    assert new["candidate"]["worktree_path"] == old_record["candidate"]["worktree_path"]
    assert new["candidate"]["branch"] == old_record["candidate"]["branch"]
    assert new["candidate"]["harness_home"] == old_record["candidate"]["harness_home"]
    [attempt] = new["attempts"]
    assert attempt["number"] == 0
    assert attempt["developer_session_id"] == "developer-session"
    refute attempt["attempt_token"] == List.last(old_record["attempts"])["attempt_token"]

    harness = new["candidate"]["harness_home"]

    assert File.read!(Path.join(harness, "fake-state/developer-invocations")) |> String.trim() ==
             "3"

    assert File.read!(Path.join(harness, "fake-state/developer-invocation-3")) =~
             ~r/^exec resume .* developer-session -$/

    prompt = File.read!(Path.join(harness, "fake-state/developer-invocation-3-prompt"))
    assert prompt =~ "Continuing Build #{old_id} after it stopped (category: provider;"

    assert prompt =~
             "Receipts from before this continuation are discarded: the controller verifies the Candidate again after your turn, and a fresh Reviewer reviews it."

    assert prompt =~ FailureHandoff.first_failure_block(old_report["signature"])
    refute prompt =~ "Controller verification failed after your turn"

    assert %{"build_id" => ^old_id} =
             Path.join(harness, "lock-seen.json") |> File.read!() |> Jason.decode!()

    assert attempt_context(new)["offline_retries"] == 3
    assert attempt_context(new)["verification_retries"] == 2

    receipts =
      Path.wildcard(
        Path.join(
          dir,
          ".kogen/runtime/scenario-tracking/#{new_id}/verification/attempt-0-#{attempt["attempt_token"]}/receipts/*"
        )
      )

    assert receipts != []

    assert Enum.all?(receipts, fn path ->
             Jason.decode!(File.read!(path))["attempt_token"] == attempt["attempt_token"]
           end)

    assert File.exists?(Path.join(harness, "fake-state/reviewer-prompt-1"))
    assert Workspace.list(dir) == []
    assert File.exists?(Path.join(dir, ".kogen/intents/complete/scripted-build"))
    assert File.read!(old_report_path) == old_report_bytes
    assert File.read!(old_path) == old_record_bytes
    assert File.exists?(new_path)
    assert old_id != new_id
  end

  test "a continuation that stops again is named by the one owner record" do
    dir = Fixture.fixture!()

    tail =
      Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("output")

    {pid, ppath, _precord} = provider_stopped!(dir)
    p_owner = owner!(dir, pid)
    p_report_bytes = File.read!(FailureReport.report_path(dir, pid))
    p_record_bytes = File.read!(ppath)

    assert {:error, message} =
             Fixture.run(dir, provider_fail: ["developer-3"], provider_tail: tail)

    assert message =~ "category: provider"
    [{c1, c1_path, _c1_record}] = new_records(dir, [pid])
    owner = owner!(dir, pid)
    assert owner["tracking_build_id"] == c1
    assert owner["status"] == "stopped: provider"

    for key <-
          ~w(worktree_path branch harness_home admitted_commit credential_bindings started_at) do
      assert owner[key] == p_owner[key]
    end

    c1_report = report!(dir, c1)
    assert c1_report["build_id"] == c1
    assert c1_report["candidate_build_id"] == pid

    assert c1_report["continues"] == %{
             "build_id" => pid,
             "record_sha256" => report!(dir, pid)["record_sha256"],
             "category" => "provider"
           }

    assert c1_report["continuable"] == true
    assert c1_report["signature"]["source"] == "stop"
    assert c1_report["budget_state"]["outer_attempt"] == 0
    assert c1_report["budget_state"]["offline_retries"] == 3
    assert c1_report["budget_state"]["offline_failures"] == 0
    assert c1_report["budget_state"]["terminal_state"] == "pending"

    output = capture_io(fn -> File.cd!(dir, fn -> Candidates.run([]) end) end)
    assert output =~ "report:  #{Workspace.canonical(FailureReport.report_path(dir, c1))}"
    refute output =~ "report:  #{Workspace.canonical(FailureReport.report_path(dir, pid))}"

    assert :ok = Fixture.run(dir)
    [{_c2, _c2_path, c2_record}] = new_records(dir, [pid, c1])
    assert c2_record["continues"]["build_id"] == c1
    assert c2_record["continues"]["record_sha256"] == c1_report["record_sha256"]
    assert attempt_context(c2_record)["offline_retries"] == 3
    h = owner["harness_home"]

    assert File.read!(Path.join(h, "fake-state/developer-invocation-4")) =~
             ~r/^exec resume .* developer-session -$/

    prompt = File.read!(Path.join(h, "fake-state/developer-invocation-4-prompt"))
    assert prompt =~ "Continuing Build #{c1} after it stopped (category: provider;"
    refute prompt =~ "## First failure"
    assert File.read!(FailureReport.report_path(dir, pid)) == p_report_bytes
    assert File.read!(ppath) == p_record_bytes
    assert File.exists?(c1_path)
  end

  test "a continuation with a new session is a session-lost stop" do
    dir = Fixture.fixture!()

    tail =
      Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("output")

    assert {:error, _} = Fixture.run(dir, provider_fail: ["developer-1"], provider_tail: tail)
    assert {:error, message} = Fixture.run(dir, new_session_on_resume: true)
    assert message =~ "category: session-lost"
  end

  test "a later continuation resume with a new session remains provider-failure" do
    dir = Fixture.fixture!()
    {pid, _path, _record} = provider_stopped!(dir)

    assert {:error, message} =
             Fixture.run(dir, fail_first: [2], new_session_on_resume_after: 3)

    assert message =~
             "resume created a new session (expected developer-session, got developer-session-2)"

    assert message =~ "category: provider-failure"
    refute message =~ "category: session-lost"
    [{cid, _cpath, _crecord}] = new_records(dir, [pid])
    assert report!(dir, cid)["category"] == "provider-failure"
  end

  test "a changed route refuses continuation" do
    dir = Fixture.fixture!()

    tail =
      Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("output")

    assert {:error, _} = Fixture.run(dir, provider_fail: ["developer-1"], provider_tail: tail)
    assert {:error, message} = Fixture.run(dir, route: "codex-alt")
    assert message =~ "Continuation refused (route-changed)"
    assert message =~ "rerun with `--route codex`"
    assert {:error, second} = Fixture.run(dir, route: "codex-alt")
    assert second =~ "Continuation refused (route-changed)"
  end

  test "changed resolved credential bindings refuse continuation" do
    dir = Fixture.fixture!()
    {id, _path, _record} = provider_stopped!(dir)
    owner_path = Workspace.owner_path(dir, id)
    owner = owner_path |> File.read!() |> Jason.decode!()

    tampered =
      Map.put(
        owner,
        "credential_bindings",
        owner["credential_bindings"] ++ [%{"harness" => "tampered"}]
      )

    File.write!(owner_path, Jason.encode!(tampered, pretty: true))
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (route-changed)"
    assert length(Fixture.records!(dir)) == 1
  end

  test "a killed continuation is reconciled in its own tracking directory" do
    dir = Fixture.fixture!()

    {pid, _ppath, precord} = provider_stopped!(dir)
    p_report_bytes = File.read!(FailureReport.report_path(dir, pid))
    standin = Fixture.start_standin!(dir, %{hang: ["developer-3"]})

    on_exit(fn ->
      try do
        Port.close(standin.port)
      rescue
        _ -> :ok
      end
    end)

    fake_pid = Fixture.await_hanging!(dir)
    System.cmd("kill", ["-9", Integer.to_string(standin.pid)])
    System.cmd("kill", ["-9", Integer.to_string(fake_pid)])
    wait_gone!(standin.pid)
    wait_gone!(fake_pid)
    [{c1, c1_path, c1_record}] = new_records(dir, [pid])
    assert owner!(dir, pid)["status"] == "running"
    assert owner!(dir, pid)["tracking_build_id"] == c1
    [{:ok, candidate}] = Workspace.list(dir)
    assert candidate["status"] == "stopped: interrupted"
    refute File.exists?(FailureReport.report_path(dir, c1))
    assert File.exists?(c1_path)
    assert :ok = Fixture.run(dir)
    c1_report = report!(dir, c1)
    assert c1_report["build_id"] == c1
    assert c1_report["candidate_build_id"] == pid
    assert c1_report["category"] == "interrupted"
    assert c1_report["continuable"] == true
    assert c1_report["next_action"] == "continue"
    assert c1_report["continues"]["build_id"] == pid
    assert c1_report["continues"]["category"] == "provider"
    assert c1_report["developer_session_id"] == "developer-session"
    assert c1_report["record_sha256"] == sha(File.read!(c1_path))
    assert c1_record["continues"]["build_id"] == pid
    assert File.read!(FailureReport.report_path(dir, pid)) == p_report_bytes
    assert attempt_context(c1_record)["offline_retries"] == 3
    h = precord["candidate"]["harness_home"]

    assert File.read!(Path.join(h, "fake-state/developer-invocation-4")) =~
             ~r/^exec resume .* developer-session -$/

    [{_c2, _path, _record}] = new_records(dir, [pid, c1])
  end

  test "a killed controller is reconciled and continued by the rerun" do
    dir = Fixture.fixture!()
    standin = Fixture.start_standin!(dir, %{fail_first: [1], hang: ["developer-2"]})

    on_exit(fn ->
      try do
        Port.close(standin.port)
      rescue
        _ -> :ok
      end
    end)

    fake = Fixture.await_hanging!(dir)
    System.cmd("kill", ["-9", Integer.to_string(standin.pid)])
    System.cmd("kill", ["-9", Integer.to_string(fake)])
    wait_gone!(standin.pid)
    wait_gone!(fake)
    [{pid, path, record}] = Fixture.records!(dir)
    bytes = File.read!(path)
    h = record["candidate"]["harness_home"]
    output = capture_io(fn -> assert :ok = Fixture.run(dir) end)
    assert output =~ "Reclaimed a stale build lock"
    assert report!(dir, pid)["category"] == "interrupted"
    assert report!(dir, pid)["continuable"] == true
    assert report!(dir, pid)["next_action"] == "continue"
    assert report!(dir, pid)["continues"] == nil
    assert report!(dir, pid)["developer_session_id"] == "developer-session"
    assert report!(dir, pid)["record_sha256"] == sha(bytes)
    [{_cid, cpath, crecord}] = new_records(dir, [pid])

    assert crecord["continues"] == %{
             "build_id" => pid,
             "record_sha256" => sha(bytes),
             "category" => "interrupted"
           }

    assert File.read!(Path.join(h, "fake-state/developer-invocation-3")) =~
             ~r/^exec resume .* developer-session -$/

    assert attempt_context(crecord)["offline_retries"] == 3
    assert File.read!(path) == bytes
    assert File.exists?(cpath)
  end

  test "a first-turn killed Candidate refuses as no-session" do
    dir = Fixture.fixture!()
    standin = Fixture.start_standin!(dir, %{hang: ["developer-1"]})

    on_exit(fn ->
      try do
        Port.close(standin.port)
      rescue
        _ -> :ok
      end
    end)

    fake = Fixture.await_hanging!(dir)
    System.cmd("kill", ["-9", Integer.to_string(standin.pid)])
    Process.sleep(200)
    System.cmd("kill", ["-9", Integer.to_string(fake)])
    [{id, _path, _record}] = Fixture.records!(dir)
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (no-session)"
    assert report!(dir, id)["category"] == "interrupted"
    assert report!(dir, id)["developer_session_id"] == nil
    assert report!(dir, id)["continuable"] == false
    assert report!(dir, id)["next_action"] == "rebuild"
    assert {:error, second} = Fixture.run(dir)
    assert second =~ "Continuation refused (no-session)"
  end

  test "continued guard reworks retain their allowance" do
    dir = Fixture.fixture!()

    assert {:error, message} =
             Fixture.run(dir,
               edits: %{1 => "touch stray.txt", 2 => "rm stray.txt"},
               fail_first: [2],
               provider_fail: ["developer-3"],
               provider_tail: tail!()
             )

    assert message =~ "category: provider"
    [{pid, _path, precord}] = Fixture.records!(dir)

    assert File.read!(
             Path.join(precord["candidate"]["harness_home"], "fake-state/developer-invocations")
           )
           |> String.trim() == "3"

    [g1] = List.last(precord["attempts"])["guard_violations"]
    assert {:error, continued} = Fixture.run(dir, edits: %{3 => "touch stray.txt"})
    assert continued =~ "category: guard-violation"
    [{cid, _cpath, crecord}] = new_records(dir, [pid])
    h = precord["candidate"]["harness_home"]
    assert File.read!(Path.join(h, "fake-state/developer-invocations")) |> String.trim() == "5"
    violations = List.last(crecord["attempts"])["guard_violations"]
    assert length(violations) == 3
    assert hd(violations) == g1
    assert cid != pid
  end

  test "changed continuation evidence is refused without a new record" do
    dir = Fixture.fixture!()

    tail =
      Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("output")

    assert {:error, _} = Fixture.run(dir, provider_fail: ["developer-1"], provider_tail: tail)
    [{_id, path, _record}] = Fixture.records!(dir)
    File.write!(path, File.read!(path) <> " ")
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (record-changed)"
    assert {:error, second} = Fixture.run(dir)
    assert second =~ "Continuation refused (record-changed)"
  end

  test "continuation set refuses an ambiguous second Candidate" do
    dir = Fixture.fixture!()
    {id, path, _record} = provider_stopped!(dir)
    copy = "copy0000000000000000000A"

    owner =
      Workspace.owner_path(dir, id)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("build_id", copy)

    File.mkdir_p!(Path.dirname(Workspace.owner_path(dir, copy)))
    File.write!(Workspace.owner_path(dir, copy), Jason.encode!(owner, pretty: true))
    File.cp_r!(Path.dirname(path), Path.join([dir, ".kogen/runtime/scenario-tracking", copy]))
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (ambiguous)"
    assert message =~ id and message =~ copy
    assert {:error, second} = Fixture.run(dir)
    assert second =~ "Continuation refused (ambiguous)"
  end

  test "publication-started, no-session, package, control, Candidate and budget refusals are reachable" do
    cases = [
      {:publication,
       fn dir, id, _path ->
         File.rm!(FailureReport.report_path(dir, id))

         record =
           Workspace.tracking_record_path(dir, id)
           |> File.read!()
           |> Jason.decode!()
           |> Map.put("status", "accepted")

         File.write!(Workspace.tracking_record_path(dir, id), Jason.encode!(record, pretty: true))
         :ok = Workspace.set_owner_status(dir, id, "running")
       end, "publication-started"},
      {:package,
       fn dir, _id, _path ->
         File.write!(
           Path.join([dir, ".kogen/intents/approved/scripted-build/intent.yaml"]),
           "# edited\n",
           [:append]
         )
       end, "package-changed"},
      {:candidate,
       fn dir, id, _path ->
         File.read!(Workspace.owner_path(dir, id))
         |> Jason.decode!()
         |> Map.fetch!("worktree_path")
         |> File.rm_rf!()
       end, "candidate-missing"}
    ]

    Enum.each(cases, fn {label, mutate, expected} ->
      dir = Fixture.fixture!()
      {id, path, _record} = provider_stopped!(dir)
      before_records = Fixture.records!(dir)
      before_owner_ids = Workspace.list(dir) |> Enum.map(fn {:ok, owner} -> owner["build_id"] end)
      before_owner = owner!(dir, id)

      before_invocations =
        Path.join(before_owner["harness_home"], "fake-state/developer-invocations")
        |> File.read!()
        |> String.trim()

      mutate.(dir, id, path)
      result = Fixture.run(dir)
      assert {:error, message} = result, "#{label}: #{inspect(result)}"
      assert message =~ "Continuation refused (#{expected})"
      assert message =~ "Candidate kept: slug scripted-build, build id #{id}"
      assert message =~ "; next action:"

      if expected == "publication-started" do
        publication_report = report!(dir, id)
        assert publication_report["category"] == "publication-interrupted"
        assert publication_report["published"] == false
        assert publication_report["next_action"] == "inspect"
        assert publication_report["continuable"] == false
      end

      assert {:error, second} = Fixture.run(dir)
      assert second =~ "Continuation refused (#{expected})"
      assert length(Fixture.records!(dir)) == length(before_records)

      assert Workspace.list(dir) |> Enum.map(fn {:ok, owner} -> owner["build_id"] end) ==
               before_owner_ids

      assert File.read!(
               Path.join(before_owner["harness_home"], "fake-state/developer-invocations")
             )
             |> String.trim() == before_invocations
    end)
  end

  test "control movement and exhausted budgets refuse continuation" do
    dir = Fixture.fixture!()
    {id, _path, _record} = provider_stopped!(dir)
    File.write!(Path.join(dir, "moved.txt"), "moved\n")
    System.cmd("git", ["add", "moved.txt"], cd: dir)
    System.cmd("git", ["commit", "-q", "-m", "moved"], cd: dir, env: git_env())
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (control-moved)"
    assert Workspace.owner_path(dir, id) |> File.exists?()
    assert {:error, second} = Fixture.run(dir)
    assert second =~ "Continuation refused (control-moved)"

    dir = Fixture.fixture!()
    {id, _path, record} = killed_provider!(dir)
    attempt = List.last(record["attempts"])

    state_path =
      Path.join(
        dir,
        ".kogen/runtime/scenario-tracking/#{id}/verification/attempt-0-#{attempt["attempt_token"]}/state.json"
      )

    state =
      state_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"offline_failures" => 5, "terminal_state" => "offline_exhausted"})

    tmp = state_path <> ".tmp"
    File.write!(tmp, Jason.encode!(state, pretty: true))
    File.rename!(tmp, state_path)
    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (budgets-exhausted)"
    exhausted = report!(dir, id)
    assert exhausted["category"] == "interrupted"
    assert exhausted["budget_state"]["terminal_state"] == "offline_exhausted"
    assert exhausted["continuable"] == false
    assert exhausted["next_action"] == "rebuild"
    assert {:error, second} = Fixture.run(dir)
    assert second =~ "Continuation refused (budgets-exhausted)"
  end

  test "publication-started refusal is independently preserved" do
    dir = Fixture.fixture!()
    {id, path, _record} = provider_stopped!(dir)
    File.rm!(FailureReport.report_path(dir, id))
    record = path |> File.read!() |> Jason.decode!() |> Map.put("status", "accepted")
    File.write!(path, Jason.encode!(record, pretty: true))
    :ok = Workspace.set_owner_status(dir, id, "running")
    assert_refusal_unchanged(dir, id, "publication-started")
    publication = report!(dir, id)
    assert publication["category"] == "publication-interrupted"
    assert publication["published"] == false
    assert publication["next_action"] == "inspect"
    assert publication["continuable"] == false
  end

  test "package-changed refusal is independently preserved" do
    dir = Fixture.fixture!()
    {id, _path, _record} = provider_stopped!(dir)

    File.write!(
      Path.join([dir, ".kogen/intents/approved/scripted-build/intent.yaml"]),
      "# edited\n",
      [:append]
    )

    assert_refusal_unchanged(dir, id, "package-changed")
  end

  test "candidate-missing refusal is independently preserved" do
    dir = Fixture.fixture!()
    {id, _path, _record} = provider_stopped!(dir)
    owner!(dir, id)["worktree_path"] |> File.rm_rf!()
    assert_refusal_unchanged(dir, id, "candidate-missing")
  end

  test "control-moved refusal is independently preserved" do
    dir = Fixture.fixture!()
    {id, _path, _record} = provider_stopped!(dir)
    File.write!(Path.join(dir, "moved-independent.txt"), "moved\n")
    System.cmd("git", ["add", "moved-independent.txt"], cd: dir)
    System.cmd("git", ["commit", "-q", "-m", "moved-independent"], cd: dir, env: git_env())
    assert_refusal_unchanged(dir, id, "control-moved")
  end

  test "budgets-exhausted refusal is independently preserved" do
    dir = Fixture.fixture!()
    {id, _path, record} = killed_provider!(dir)
    attempt = List.last(record["attempts"])

    state_path =
      Path.join(
        dir,
        ".kogen/runtime/scenario-tracking/#{id}/verification/attempt-0-#{attempt["attempt_token"]}/state.json"
      )

    state =
      state_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"offline_failures" => 5, "terminal_state" => "offline_exhausted"})

    tmp = state_path <> ".tmp"
    File.write!(tmp, Jason.encode!(state, pretty: true))
    File.rename!(tmp, state_path)
    assert_refusal_unchanged(dir, id, "budgets-exhausted")
    exhausted = report!(dir, id)
    assert exhausted["category"] == "interrupted"
    assert exhausted["budget_state"]["terminal_state"] == "offline_exhausted"
    assert exhausted["continuable"] == false
    assert exhausted["next_action"] == "rebuild"
  end

  test "session-lost report is retained and the next rerun starts fresh" do
    dir = Fixture.fixture!()
    {pid, _path, precord} = provider_stopped!(dir)
    p_worktree = precord["candidate"]["worktree_path"]
    assert {:error, message} = Fixture.run(dir, new_session_on_resume: true)
    assert message =~ "category: session-lost"
    records = Fixture.records!(dir)
    {cid, _, report_record} = Enum.find(records, fn {_id, _, r} -> r["continues"] end)
    report = report!(dir, cid)
    assert report["category"] == "session-lost"
    assert report["class"] == "interrupted"
    assert report["next_action"] == "rebuild"
    assert report["continuable"] == false
    assert report["counts_toward"] == nil
    assert report["continues"]["build_id"] == pid
    assert owner!(dir, pid)["status"] == "stopped: session-lost"
    assert owner!(dir, pid)["tracking_build_id"] == cid
    assert :ok = Fixture.run(dir)

    [{fresh_id, _fresh_path, fresh_record}] =
      Fixture.records!(dir)
      |> Enum.filter(fn {id, _, r} -> id != pid and id != cid and is_nil(r["continues"]) end)

    assert fresh_id not in [pid, cid]
    assert fresh_record["candidate"]["worktree_path"] != p_worktree
    assert owner!(dir, pid)["status"] == "stopped: session-lost"
    assert File.dir?(p_worktree)

    assert report_record["continues"]["build_id"] == pid

    fresh = Fixture.fixture!()

    assert {:error, fresh_message} =
             Fixture.run(fresh, fail_first: [1], new_session_on_resume: true)

    assert fresh_message =~
             "resume created a new session (expected developer-session, got developer-session-2)"

    assert fresh_message =~ "category: provider-failure"
  end

  defp tail! do
    Path.expand("../support/provider_tails/be_n9crq_claude_session_limit.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("output")
  end

  defp provider_stopped!(dir) do
    assert {:error, message} =
             Fixture.run(dir,
               fail_first: [1],
               provider_fail: ["developer-2"],
               provider_tail: tail!()
             )

    assert message =~ "category: provider"
    [{id, path, record}] = Fixture.records!(dir)
    {id, path, record}
  end

  defp killed_provider!(dir) do
    standin = Fixture.start_standin!(dir, %{fail_first: [1], hang: ["developer-2"]})

    on_exit(fn ->
      try do
        Port.close(standin.port)
      rescue
        _ -> :ok
      end
    end)

    fake = Fixture.await_hanging!(dir)
    System.cmd("kill", ["-9", Integer.to_string(standin.pid)])
    Process.sleep(200)
    System.cmd("kill", ["-9", Integer.to_string(fake)])
    [{id, path, record}] = Fixture.records!(dir)
    {id, path, record}
  end

  defp report!(dir, id), do: FailureReport.report_path(dir, id) |> File.read!() |> Jason.decode!()

  defp owner!(dir, id), do: Workspace.owner_path(dir, id) |> File.read!() |> Jason.decode!()

  defp new_records(dir, previous) do
    Fixture.records!(dir) |> Enum.reject(fn {id, _path, _record} -> id in previous end)
  end

  defp assert_refusal_unchanged(dir, id, expected) do
    before_records =
      Fixture.records!(dir)
      |> Enum.map(fn {record_id, path, _record} -> {record_id, File.read!(path)} end)

    before_owner_ids =
      Workspace.list(dir) |> Enum.map(fn {:ok, owner} -> owner["build_id"] end) |> Enum.sort()

    before_tracking_dirs =
      Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*")) |> Enum.sort()

    owner = owner!(dir, id)
    harness = owner["harness_home"]
    worktree = owner["worktree_path"]
    before_invocations = File.read!(Path.join(harness, "fake-state/developer-invocations"))
    before_tree = if File.dir?(worktree), do: tree!(worktree), else: :missing

    assert {:error, message} = Fixture.run(dir)
    assert message =~ "Continuation refused (#{expected})"
    assert message =~ "Candidate kept: slug scripted-build, build id #{id}"
    assert message =~ "; next action:"
    assert {:error, second} = Fixture.run(dir)
    assert second =~ "Continuation refused (#{expected})"

    after_records =
      Fixture.records!(dir)
      |> Enum.map(fn {record_id, path, _record} -> {record_id, File.read!(path)} end)

    assert after_records == before_records

    assert Workspace.list(dir)
           |> Enum.map(fn {:ok, owner} -> owner["build_id"] end)
           |> Enum.sort() ==
             before_owner_ids

    assert Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*")) |> Enum.sort() ==
             before_tracking_dirs

    assert File.read!(Path.join(harness, "fake-state/developer-invocations")) ==
             before_invocations

    assert not File.exists?(Workspace.lock_path(dir))

    if before_tree == :missing do
      refute File.dir?(worktree)
    else
      assert tree!(worktree) == before_tree
    end
  end

  defp attempt_context(record) do
    attempt = List.last(record["attempts"])
    Base.decode64!(attempt["verification_context"]["content_base64"]) |> Jason.decode!()
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

  defp tree!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&(String.contains?(&1, "/.git/") or &1 == Path.join(root, ".git")))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, root), sha(File.read!(path))} end)
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "Fixture"},
      {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Fixture"},
      {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"}
    ]
  end
end
