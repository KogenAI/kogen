defmodule Kogen.ScenarioLifecycleTest do
  @moduledoc "Offline lifecycle controls for controller-built handoff reports and findings."
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build
  alias Kogen.Build.Evidence

  @slug "scenario-lifecycle"
  @root Path.expand("../..", __DIR__)

  for mode <-
        ~w(handoff_missing handoff_stale handoff_incomplete handoff_duplicate handoff_unknown) do
    test "#{mode} old-shape JSON notes are never validated and reach Review in one attempt" do
      dir = fixture!()
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok = run(dir, unquote(mode))
      assert File.read!(fake_state_path(dir, "reviews")) == "1"
      refute File.exists?(fake_state_path(dir, "resume-sessions"))
      [attempt] = record!(dir)["attempts"]
      notes = File.read!(fake_state_path(dir, "developer-notes-1"))
      assert attempt["developer_notes"]["text"] == notes
      assert attempt["handoff"]["built_by"] == "controller"
      assert Enum.map(attempt["handoff"]["scenarios"], & &1["id"]) == ["first"]
    end
  end

  for mode <- ~w(output_missing output_empty output_truncated) do
    test "settled #{mode} notes are recorded verbatim and reach Review without correction" do
      dir = fixture!()
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok = run(dir, unquote(mode))
      [attempt] = record!(dir)["attempts"]

      expected =
        if unquote(mode) == "output_missing",
          do: "",
          else: File.read!(fake_state_path(dir, "developer-notes-1"))

      assert Base.decode64!(attempt["developer_notes"]["content_base64"]) == expected
      assert attempt["developer_notes"]["label"] =~ "unverified"
      refute attempt["failure"]
      refute File.exists?(fake_state_path(dir, "resume-sessions"))
      assert File.read!(fake_state_path(dir, "reviews")) == "1"
    end
  end

  for mode <- ~w(developer_exit developer_error missing_settlement) do
    test "#{mode} remains a provider failure and never reaches Review" do
      dir = fixture!()
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, reason} = run(dir, unquote(mode))
      assert reason =~ "harness failure during Developer turn"
      [attempt] = record!(dir)["attempts"]
      assert attempt["developer_invocation"]["outcome"] == "provider_failure"
      refute Map.has_key?(attempt["developer_invocation"], "message")
      refute File.exists?(fake_state_path(dir, "reviews"))
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
      assert_retained!(dir, reason, "provider-failure")
    end
  end

  test "Build retains each Developer invocation's notes and carries no handoff schema" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = run(dir, "review_evidence")
    [first, reworked] = record!(dir)["attempts"]

    for {attempt, call} <- [{first, 1}, {reworked, 2}] do
      invocation = attempt["developer_invocation"]
      refute Map.has_key?(invocation, "schema")
      refute Map.has_key?(invocation, "schema_sha256")
      assert invocation["outcome"] == "settled"
      assert invocation["session_id"] == "developer-session"
      notes = File.read!(fake_state_path(dir, "developer-notes-#{call}"))
      assert invocation["message"] == notes
      assert attempt["developer_notes"]["text"] == notes
      assert invocation["message_sha256"] == sha256(notes)
      assert attempt["developer_notes"]["sha256"] == sha256(notes)
      assert attempt["handoff"]["attempt_token"] == attempt["attempt_token"]
    end
  end

  test "invalid Review retains all entry diagnoses and stops without publication" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, reason} = run(dir, "verdict_diagnostics")
    assert reason =~ "Reviewer failure"
    assert reason =~ "path \"lib\""
    assert reason =~ "found directory"
    assert reason =~ "path \"/etc/hosts\""
    assert reason =~ "unsafe path"
    record = record!(dir)
    assert List.last(record["attempts"])["failure"] =~ "found directory"
    assert [%{"id" => "F1", "status" => "open", "disposition_history" => []}] = record["findings"]
    assert File.read!(fake_state_path(dir, "reviews")) == "2"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert_retained!(dir, reason, "review-failure")
  end

  test "target failure preserves cumulative findings through the last allowed rework" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, reason} = run(dir, "target_history")
    assert reason =~ "verification retries exhausted"
    refute reason =~ "outer resumption"

    record = record!(dir)
    assert Enum.map(record["findings"], & &1["id"]) == ["F1", "F2"]
    assert Enum.all?(record["findings"], &(&1["status"] == "open"))

    assert Enum.any?(
             record["attempts"],
             &String.contains?(&1["failure"] || "", "verification retries exhausted")
           )

    assert_retained!(dir, reason, "verification-exhausted")
  end

  test "partial repair and dispute retain finding identities and dispositions" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = run(dir, "partial_dispute")
    [first, second] = record!(dir)["findings"]
    assert first["id"] == "F1"
    assert second["id"] == "F2"
    assert Enum.any?(first["disposition_history"], &(&1["status"] == "open"))
    assert Enum.any?(second["disposition_history"], &(&1["status"] == "closed"))
  end

  test "fresh review reassesses a changed Candidate and records a regression finding" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = run(dir, "regression")
    record = record!(dir)

    candidates =
      record["attempts"]
      |> Enum.map(& &1["candidate_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert length(candidates) >= 2
    assert Enum.map(record["findings"], & &1["id"]) == ["F1", "F2"]

    assert Enum.all?(
             record["attempts"],
             &(Map.has_key?(&1, "verdict") or &1["status"] == "failed")
           )
  end

  test "exhaustion preserves unique records without raw logs and publication copies closure evidence" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, reason} = run(dir, "exhaust")
    [first] = records(dir)
    refute File.exists?(Path.join(dir, ".kogen/runtime/raw"))
    assert_retained!(dir, reason, "outer-allowance-exhausted")

    assert {:error, _} = run(dir, "exhaust")
    assert Enum.count(records(dir)) == 2
    assert File.regular?(first)

    complete = fixture!()
    on_exit(fn -> File.rm_rf(complete) end)
    assert :ok = run(complete, "accept")

    [closure] = records(complete)

    [summary] =
      Path.wildcard(Path.join(complete, ".kogen/intents/complete/#{@slug}/build-summary*.json"))

    closure_record = Jason.decode!(File.read!(closure))
    summary_record = Jason.decode!(File.read!(summary))
    assert closure_record["status"] == "accepted"
    assert summary_record["full_record"]["sha256"] == sha256(File.read!(closure))

    assert File.read!(Path.join(complete, ".kogen/intents/complete/#{@slug}/evidence.md")) =~
             summary_record["full_record"]["path"]
  end

  test "tracking record mutation stops the Build without publishing" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    {result, candidate} =
      run_with_control_mutation!(dir, "record_mutation", fn ->
        [record_path] = records(dir)
        File.write!(record_path, File.read!(record_path) <> " tampered")
      end)

    assert {:error, reason} = result
    assert reason =~ "scenario tracking record changed outside Build"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert_retained_snapshot!(candidate, reason, "integrity")
  end

  test "a malformed later verdict cannot partially close retained findings" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:error, reason} = run(dir, "omitted_disposition")
    assert reason =~ "Reviewer failure"
    assert reason =~ "finding dispositions: missing expected ID \"F1\""
    record = record!(dir)
    assert [%{"id" => "F1", "status" => "open", "disposition_history" => []}] = record["findings"]
    assert File.read!(fake_state_path(dir, "reviews")) == "2"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert_retained!(dir, reason, "review-failure")
  end

  test "rework reference bytes remain self-contained after the original runtime evidence disappears" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert :ok = run(dir, "review_evidence")
    refute File.exists?(Path.join(dir, ".kogen/runtime/review-proof.txt"))
    [first | _] = record!(dir)["attempts"]
    snapshot = first["reference_snapshots"][".kogen/runtime/review-proof.txt"]

    assert Base.decode64!(snapshot["content_base64"]) ==
             "independently inspected first-candidate evidence"

    closure = record!(dir)

    assert hd(closure["attempts"])["reference_snapshots"] == first["reference_snapshots"]
  end

  test "record citations survive owned rework and publication updates with historical bytes retained" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert :ok = run(dir, "record_citations")
    assert File.read!(fake_state_path(dir, "reviews")) == "2"
    record = record!(dir)
    assert record["status"] == "accepted"
    assert [%{"id" => "F1", "status" => "closed"}] = record["findings"]
    path = records(dir) |> List.first() |> Path.relative_to(dir)
    record_bytes = File.read!(Path.join(dir, path))

    inspected =
      for {attempt, call} <- Enum.with_index(record["attempts"], 1) do
        inspected = File.read!(fake_state_path(dir, "reviewer-inspected-#{call}.json"))
        sidecar = Path.join(Path.dirname(path), "record-versions/#{sha256(inspected)}.json")

        for key <- ~w(reviewer_reference_snapshots reference_snapshots) do
          assert attempt[key][path] == %{
                   "path" => path,
                   "sha256" => sha256(inspected),
                   "byte_count" => byte_size(inspected),
                   "binding" => "controller_record_version",
                   "sidecar" => sidecar
                 }
        end

        # The sidecar holds exactly the version the Reviewer inspected.
        assert File.read!(Path.join(dir, sidecar)) == inspected

        # Ordinary cited files keep their inline snapshots.
        makefile = attempt["reviewer_reference_snapshots"]["Makefile"]

        assert Base.decode64!(makefile["content_base64"]) ==
                 File.read!(Path.join(dir, "Makefile"))

        # A record path in the Developer's notes is never parsed into a citation;
        # the controller report cites only Candidate files and selectors.
        assert attempt["developer_notes"]["text"] =~ path
        refute Map.has_key?(attempt["developer_reference_snapshots"], path)
        inspected
      end

    # No record version contains an earlier one, so the record stays smaller
    # than the versions it cites.
    versions = Path.wildcard(Path.join(dir, Path.dirname(path) <> "/record-versions/*.json"))
    assert Enum.sort(Enum.map(versions, &File.read!/1)) == Enum.sort(inspected)
    assert byte_size(record_bytes) < Enum.sum(Enum.map(inspected, &byte_size/1))

    for version <- inspected ++ Enum.map(versions, &File.read!/1) do
      refute record_bytes =~ Base.encode64(version)
    end

    [summary] =
      Path.wildcard(Path.join(dir, ".kogen/intents/complete/#{@slug}/build-summary*.json"))

    assert Jason.decode!(File.read!(summary))["full_record"]["sha256"] == sha256(record_bytes)
    assert {:ok, _record} = File.cd!(dir, fn -> Evidence.resolve(summary) end)

    # Evidence resolution validates every referenced sidecar.
    [first_sidecar | _] = versions
    File.write!(first_sidecar, "edited")

    assert {:error, reason} = File.cd!(dir, fn -> Evidence.resolve(summary) end)
    assert reason =~ "sidecar"
  end

  for {mode, message} <- [
        record_sidecar_delete: "record version sidecar missing",
        record_sidecar_edit: "record version sidecar mutated"
      ] do
    test "#{mode} of a retained record version before publication stops the Build" do
      dir = fixture!()
      on_exit(fn -> File.rm_rf(dir) end)
      mode_string = unquote(Atom.to_string(mode))

      {result, _candidate} =
        run_with_control_mutation!(dir, mode_string, fn ->
          [record_path] = records(dir)

          [sidecar] =
            Path.wildcard(Path.join(Path.dirname(record_path), "record-versions/*.json"))

          case mode_string do
            "record_sidecar_delete" -> File.rm!(sidecar)
            "record_sidecar_edit" -> File.write!(sidecar, File.read!(sidecar) <> " edited")
          end
        end)

      assert {:error, reason} = result
      assert reason =~ unquote(message)
      assert File.read!(fake_state_path(dir, "reviews")) == "2"
      assert File.dir?(Path.join(dir, ".kogen/intents/approved/#{@slug}"))
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
      # Only a retained sidecar was mutated; the tracking record itself
      # stays valid JSON, so the ordinary retention assertion applies.
      assert_retained!(dir, reason, "review-failure")
    end
  end

  test "citing the record never permits a Reviewer to change it" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    {result, candidate} =
      run_with_control_mutation!(dir, "record_citation_tamper", fn ->
        [record_path] = records(dir)
        File.write!(record_path, File.read!(record_path) <> " tampered by Reviewer")
      end)

    assert {:error, reason} = result
    assert reason =~ "scenario tracking record changed outside Build"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert File.read!(Path.join(candidate["harness_home"], "fake-state/reviews")) == "1"
    assert_retained_snapshot!(candidate, reason, "review-failure")
  end

  test "declared target evidence retains all artifacts separately from Reviewer citations" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert :ok = run(dir, "target_evidence")

    record = record!(dir)

    receipt =
      record["attempts"]
      |> List.last()
      |> Map.fetch!("receipts")
      |> Enum.find(&(&1["target"] == "verify"))

    retained = receipt["target_evidence"]
    assert retained["target"] == "verify"
    assert retained["attempt_token"] == List.last(record["attempts"])["attempt_token"]
    refute receipt["output"] =~ "PRIVATE_TARGET_SENTINEL"

    for snapshot <- [retained["manifest"] | retained["required_evidence"]] do
      decoded = Base.decode64!(snapshot["content_base64"])
      assert snapshot["sha256"] == Base.encode16(:crypto.hash(:sha256, decoded), case: :lower)
    end

    assert Enum.map(retained["required_evidence"], fn snapshot ->
             {snapshot["path"], Base.decode64!(snapshot["content_base64"])}
           end) == [
             {".kogen/runtime/target-evidence/semantic.txt", "reviewed behavior\n"},
             {".kogen/runtime/target-evidence/uncited.bin", <<0, 7, 255>>}
           ]

    reviewer = List.last(record["attempts"])["reviewer_reference_snapshots"]
    assert Map.has_key?(reviewer, ".kogen/runtime/target-evidence/semantic.txt")
    refute Map.has_key?(reviewer, ".kogen/runtime/target-evidence/uncited.bin")

    File.rm_rf!(Path.join(dir, ".kogen/runtime/target-evidence"))
    complete_record = record!(dir)

    complete_retained =
      complete_record["attempts"]
      |> List.last()
      |> Map.fetch!("receipts")
      |> Enum.find(&(&1["target"] == "verify"))
      |> Map.fetch!("target_evidence")

    assert complete_retained == retained
  end

  test "target evidence source mutation after Review prevents publication" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:error, reason} = run(dir, "target_evidence_mutation")
    assert reason =~ "bound target evidence changed"
    assert File.dir?(Path.join(dir, ".kogen/intents/approved/#{@slug}"))
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert_retained!(dir, reason, "review-failure")
  end

  # A second Build of the same Intent, started after the first was stopped
  # and its Candidate retained, gets its own new Candidate and harness home;
  # the first Build's Candidate (worktree, branch, harness home, owner
  # record) is left exactly as it was.
  test "a second Build after a stop gets a new Candidate and leaves the first retained" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, _reason} = run(dir, "developer_exit")
    first = Kogen.CandidateFixture.candidate(dir)
    first_owner_before = first["owner_record"] |> File.read!()
    first_worktree_files_before = File.ls!(first["worktree_path"]) |> Enum.sort()

    assert {:error, _reason} = run(dir, "developer_exit")
    second = Kogen.CandidateFixture.candidate(dir)

    refute second["worktree_path"] == first["worktree_path"]
    refute second["harness_home"] == first["harness_home"]
    refute second["owner_record"] == first["owner_record"]
    assert second["disposition"] == "retained"

    # The first Candidate's worktree, branch, harness home and owner record
    # are untouched by the second Build.
    assert File.dir?(first["worktree_path"])
    assert File.ls!(first["worktree_path"]) |> Enum.sort() == first_worktree_files_before
    assert File.read!(first["owner_record"]) == first_owner_before
    assert File.dir?(first["harness_home"])

    worktrees = Kogen.CandidateFixture.registered_worktrees(dir)
    assert first["worktree_path"] in worktrees
    assert second["worktree_path"] in worktrees
  end

  defp run(dir, mode) do
    previous_harness = System.get_env("KOGEN_HARNESS")
    previous_mode = System.get_env("SCENARIO_LIFECYCLE_MODE")
    previous_raw = System.get_env("KOGEN_RAW_LOG_DIR")
    System.put_env("KOGEN_HARNESS", Path.join(dir, "scenario-lifecycle-harness.py"))
    System.put_env("SCENARIO_LIFECYCLE_MODE", mode)
    System.delete_env("KOGEN_RAW_LOG_DIR")

    try do
      File.cd!(dir, fn -> Build.run(@slug, nil, dir) end)
    after
      restore("KOGEN_HARNESS", previous_harness)
      restore("SCENARIO_LIFECYCLE_MODE", previous_mode)
      restore("KOGEN_RAW_LOG_DIR", previous_raw)
    end
  end

  defp fixture! do
    dir =
      Path.join(System.tmp_dir!(), "kogen-scenario-life-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, ".codex/hooks"))
    File.mkdir_p!(Path.join(dir, "priv/kogen/prompts"))
    File.mkdir_p!(Path.join(dir, "lib"))
    # Git never tracks an empty directory; without a committed file inside
    # it, `lib` would exist in control but not in the Candidate worktree
    # checked out from Git objects, breaking scenarios that cite it as a
    # directory.
    File.write!(Path.join(dir, "lib/.gitkeep"), "")

    for path <- [
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          ".codex/hooks.json",
          "priv/kogen/prompts/execution-policy.md",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md"
        ] do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, path), target)
    end

    File.cp!(
      Path.join(@root, "test/support/scenario_lifecycle_harness.py"),
      Path.join(dir, "scenario-lifecycle-harness.py")
    )

    File.chmod!(Path.join(dir, ".codex/hooks/check.sh"), 0o755)
    File.chmod!(Path.join(dir, "scenario-lifecycle-harness.py"), 0o755)

    File.write!(Path.join(dir, "target-evidence-producer.py"), target_evidence_producer())
    File.chmod!(Path.join(dir, "target-evidence-producer.py"), 0o755)

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/runtime/\n.kogen/build.lock\n.kogen/intents/approved/\n"
    )

    File.write!(
      Path.join(dir, ".kogen/config.yaml") |> tap(&File.mkdir_p!(Path.dirname(&1))),
      config()
    )

    File.write!(
      Path.join(dir, "Makefile"),
      "check:\n\t@true\nverify:\n\t@if echo \"$$SCENARIO_LIFECYCLE_MODE\" | grep -q '^target_evidence'; then ./target-evidence-producer.py; else test ! -f .kogen/runtime/fail-target; fi\n"
    )

    File.write!(Path.join(dir, "dummy.txt"), "baseline\n")
    intent = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent)

    File.write!(
      Path.join(intent, "intent.yaml"),
      "id: 01960000-0000-7000-8000-00000000aa11\nslug: #{@slug}\ntitle: Scenario lifecycle\nmay_change_guarded_paths: [dummy.txt]\n"
    )

    File.write!(Path.join(intent, "scenarios.yaml"), scenarios())
    Kogen.VerificationFixture.install!(dir)

    File.write!(
      Path.join(intent, "risks.yaml"),
      "- id: lifecycle-risk\n  scenario_ids: [first]\n  description: fixture ownership\n"
    )

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dir, "deps"))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "baseline"])
    dir
  end

  defp scenarios,
    do:
      "- id: first\n  given: a Candidate\n  when: Build reviews it\n  then: it is tracked\n  wrong_result: it is skipped\n  verified_by: [check, verify]\n  evidence: fixture\n"

  defp config,
    do:
      "default_route: codex\nroutes:\n  codex:\n    harness: codex\n    shaping: {model: fake, effort: low}\n    developer: {model: fake, effort: low}\n    reviewer: {model: fake, effort: low}\n    helpers:\n      scout: {model: fake, effort: low}\n      worker: {model: fake, effort: medium}\n      expert: {model: fake, effort: medium}\nouter_resumptions: 2\nverification_retries: 2\n"

  defp target_evidence_producer do
    ~S'''
    #!/usr/bin/env python3
    import hashlib, json, pathlib
    root = pathlib.Path(".kogen/runtime/target-evidence")
    root.mkdir(parents=True, exist_ok=False)
    items = [("semantic.txt", b"reviewed behavior\n"), ("uncited.bin", bytes([0, 7, 255]))]
    required = []
    for name, content in items:
        path = root / name
        path.write_bytes(content)
        required.append({"path": str(path), "sha256": hashlib.sha256(content).hexdigest()})
    manifest = root / "manifest.json"
    manifest.write_bytes(json.dumps({"schema_version": 1, "required_evidence": required}, separators=(",", ":")).encode())
    locator = {"manifest_path": str(manifest), "sha256": hashlib.sha256(manifest.read_bytes()).hexdigest()}
    print("unterminated progress", end="")
    print("KOGEN_TARGET_EVIDENCE_MANIFEST\t" + json.dumps(locator, separators=(",", ":")))
    '''
  end

  defp record!(dir), do: records(dir) |> List.last() |> File.read!() |> Jason.decode!()

  defp records(dir),
    do: Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))

  defp sha256(bytes),
    do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp git!(dir, args), do: System.cmd("git", args, cd: dir, env: git_env())

  defp git_env,
    do: [
      {"GIT_AUTHOR_NAME", "Fixture"},
      {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Fixture"},
      {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"}
    ]

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  # Scratch the fake harness must still find after the Build (kept in the
  # harness home; a successful publish removes the Candidate worktree).
  defp fake_state_path(dir, name), do: Kogen.CandidateFixture.fake_state(dir, name)

  # A stop keeps the Candidate worktree, branch and harness home exactly as
  # they are: control (its checkout and Approved package) is unchanged, the
  # tracking record's `candidate` block is `retained`, the stop message names
  # the slug, build id, worktree, branch and harness home next to the
  # tracking record path plus the removal command, and the Candidate's own
  # owner record independently agrees on `stopped: <category>`.
  defp assert_retained!(dir, reason, expected_category) do
    candidate = Kogen.CandidateFixture.candidate(dir)
    assert candidate["disposition"] == "retained"

    worktree = candidate["worktree_path"]
    assert File.dir?(worktree)
    assert File.dir?(candidate["harness_home"])
    assert worktree in Kogen.CandidateFixture.registered_worktrees(dir)

    owner_record = candidate["owner_record"] |> File.read!() |> Jason.decode!()
    build_id = owner_record["build_id"]
    assert owner_record["status"] == "stopped: #{expected_category}"

    assert reason =~
             "Candidate kept: slug #{@slug}, build id #{build_id}, worktree #{worktree}, " <>
               "branch #{candidate["branch"]}, harness home #{candidate["harness_home"]}; " <>
               "remove it with `mix kogen.candidates.remove #{build_id}`"
  end

  # The four modes below tamper with control's own tracking record or one of
  # its retained sidecars, a control-side write that is outside the launched
  # fake role's write boundary. The role signals the intended mutation from
  # inside its own writable Candidate; only the trusted test process (never
  # sandboxed, holding control) may perform it. Returns `{result, candidate}`,
  # `candidate` being the record's `candidate` block read just before the
  # mutation (a record-corrupting mutation, unlike a sidecar-only one, leaves
  # the tracking record permanently unparseable, since `Tracking.update`
  # refuses to persist over bytes it no longer recognizes as its own).
  defp run_with_control_mutation!(dir, mode, mutate) do
    task = Task.async(fn -> run(dir, mode) end)
    candidate = wait_for_candidate!(dir)
    worktree = candidate["worktree_path"]
    marker = Path.join(worktree, ".kogen/runtime/mutation-request-#{mode}")
    wait_for_file!(marker)
    mutate.()
    File.write!(Path.join(worktree, ".kogen/runtime/mutation-ack-#{mode}"), "go")
    {Task.await(task, 30_000), candidate}
  end

  defp wait_for_candidate!(dir, attempts \\ 500)

  defp wait_for_candidate!(_dir, 0),
    do: flunk("Candidate worktree did not appear in time")

  defp wait_for_candidate!(dir, attempts) do
    case records(dir) do
      [] ->
        Process.sleep(20)
        wait_for_candidate!(dir, attempts - 1)

      paths ->
        record = paths |> List.last() |> File.read!() |> Jason.decode!()

        case record["candidate"] do
          %{"worktree_path" => _path} = candidate ->
            candidate

          _ ->
            Process.sleep(20)
            wait_for_candidate!(dir, attempts - 1)
        end
    end
  end

  # Like `assert_retained!/3`, but from a `candidate` block captured before a
  # mutation that leaves the tracking record permanently unparseable: only
  # the Candidate's own owner record (a separate file, updated unconditionally
  # by every stop) can still be read afterward.
  defp assert_retained_snapshot!(candidate, reason, expected_category) do
    worktree = candidate["worktree_path"]
    assert File.dir?(worktree)
    assert File.dir?(candidate["harness_home"])

    owner_record = candidate["owner_record"] |> File.read!() |> Jason.decode!()
    build_id = owner_record["build_id"]
    assert owner_record["status"] == "stopped: #{expected_category}"

    assert reason =~
             "Candidate kept: slug #{@slug}, build id #{build_id}, worktree #{worktree}, " <>
               "branch #{candidate["branch"]}, harness home #{candidate["harness_home"]}; " <>
               "remove it with `mix kogen.candidates.remove #{build_id}`"
  end

  defp wait_for_file!(path, attempts \\ 1000)
  defp wait_for_file!(path, 0), do: flunk("expected marker file did not appear: #{path}")

  defp wait_for_file!(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_for_file!(path, attempts - 1)
    end
  end
end
