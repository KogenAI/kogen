defmodule Kogen.ScenarioLifecycleTest do
  @moduledoc "Offline lifecycle controls for scenario-bound handoffs and findings."
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build

  @slug "scenario-lifecycle"
  @root Path.expand("../..", __DIR__)

  for mode <-
        ~w(handoff_missing handoff_stale handoff_incomplete handoff_duplicate handoff_unknown) do
    test "#{mode} handoff blocks Review then corrects in the exact Developer session" do
      dir = fixture!()
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok = run(dir, unquote(mode))
      assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
      assert File.read!(Path.join(dir, ".kogen/runtime/resume-sessions")) == "developer-session\n"
    end
  end

  for mode <- ~w(output_missing output_empty output_truncated) do
    test "settled #{mode} output is a bounded structural correction in the same session" do
      dir = fixture!()
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok = run(dir, unquote(mode))
      [failed, corrected] = record!(dir)["attempts"]
      assert failed["failure"] =~ "Developer handoff structure invalid"
      assert failed["developer_session_id"] == "developer-session"
      assert corrected["developer_session_id"] == "developer-session"
      assert File.read!(Path.join(dir, ".kogen/runtime/resume-sessions")) == "developer-session\n"
      assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
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
      refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    end
  end

  test "handoff diagnostics reach the resumed Developer through the retained attempt" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = run(dir, "handoff_diagnostics")
    assert File.regular?(Path.join(dir, ".kogen/runtime/developer-verified-diagnostics"))
    [failed, _corrected] = record!(dir)["attempts"]
    assert failed["failure"] =~ "path \"lib\""
    assert failed["failure"] =~ "found directory"
    assert failed["failure"] =~ "field response must be nonblank text"
    assert File.read!(Path.join(dir, ".kogen/runtime/resume-sessions")) == "developer-session\n"
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
  end

  test "Build retains each owned Developer schema and final message after invocation cleanup" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = run(dir, "handoff_stale")
    [first, corrected] = record!(dir)["attempts"]

    for attempt <- [first, corrected] do
      invocation = attempt["developer_invocation"]
      schema = Jason.decode!(invocation["schema"])
      assert invocation["outcome"] == "settled"
      assert invocation["session_id"] == "developer-session"

      assert invocation["schema_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, invocation["schema"]), case: :lower)

      assert invocation["message_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, invocation["message"]), case: :lower)

      assert schema["properties"]["attempt_token"]["enum"] == [attempt["attempt_token"]]
      assert schema["properties"]["scenarios"]["minItems"] == 1
      assert schema["properties"]["risks"]["minItems"] == 1
    end

    refute first["developer_invocation"]["schema"] == corrected["developer_invocation"]["schema"]
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
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "2"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
  end

  test "target failure preserves cumulative findings through the last allowed rework" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, reason} = run(dir, "target_history")
    assert reason =~ "verification retries exhausted"

    record = record!(dir)
    assert Enum.map(record["findings"], & &1["id"]) == ["F1", "F2"]
    assert Enum.all?(record["findings"], &(&1["status"] == "open"))

    assert Enum.any?(
             record["attempts"],
             &String.contains?(&1["failure"] || "", "verification retries exhausted")
           )
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

    assert {:error, _} = run(dir, "exhaust")
    [first] = records(dir)
    refute File.exists?(Path.join(dir, ".kogen/runtime/raw"))

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

    assert {:error, reason} = run(dir, "record_mutation")
    assert reason =~ "scenario tracking record changed outside Build"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
  end

  test "a malformed later verdict cannot partially close retained findings" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:error, reason} = run(dir, "omitted_disposition")
    assert reason =~ "Reviewer failure"
    assert reason =~ "finding dispositions: missing expected ID \"F1\""
    record = record!(dir)
    assert [%{"id" => "F1", "status" => "open", "disposition_history" => []}] = record["findings"]
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "2"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
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
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "2"
    record = record!(dir)
    assert record["status"] == "accepted"
    assert [%{"id" => "F1", "status" => "closed"}] = record["findings"]
    path = records(dir) |> List.first() |> Path.relative_to(dir)

    for {attempt, call} <- Enum.with_index(record["attempts"], 1) do
      for role <- ~w(developer reviewer) do
        snapshot = attempt["#{role}_reference_snapshots"][path]
        assert snapshot["binding"] == "controller_record_version"
        inspected = File.read!(Path.join(dir, ".kogen/runtime/#{role}-inspected-#{call}.json"))
        assert Base.decode64!(snapshot["content_base64"]) == inspected
        assert snapshot["sha256"] == Base.encode16(:crypto.hash(:sha256, inspected))
      end

      refute attempt["developer_reference_snapshots"][path] ==
               attempt["reviewer_reference_snapshots"][path]
    end

    [summary] =
      Path.wildcard(Path.join(dir, ".kogen/intents/complete/#{@slug}/build-summary*.json"))

    assert Jason.decode!(File.read!(summary))["full_record"]["sha256"] ==
             sha256(File.read!(List.first(records(dir))))
  end

  test "citing the record never permits a Reviewer to change it" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:error, reason} = run(dir, "record_citation_tamper")
    assert reason =~ "scenario tracking record changed outside Build"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
  end

  test "declared target evidence retains all artifacts separately from Reviewer citations" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert :ok = run(dir, "target_evidence")

    record = record!(dir)
    receipt = record["attempts"] |> List.last() |> Map.fetch!("targets") |> List.first()
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
      |> Map.fetch!("targets")
      |> List.first()
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
  end

  defp run(dir, mode) do
    previous_harness = System.get_env("KOGEN_HARNESS")
    previous_mode = System.get_env("SCENARIO_LIFECYCLE_MODE")
    previous_raw = System.get_env("KOGEN_RAW_LOG_DIR")
    System.put_env("KOGEN_HARNESS", Path.join(dir, "scenario-lifecycle-harness.py"))
    System.put_env("SCENARIO_LIFECYCLE_MODE", mode)
    System.delete_env("KOGEN_RAW_LOG_DIR")

    try do
      File.cd!(dir, fn -> Build.run(@slug) end)
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
      "harness: codex\nshaping: {model: fake, effort: low}\ndeveloper: {model: fake, effort: low}\nreviewer: {model: fake, effort: low}\nhelpers:\n  scout: {model: fake, effort: low}\n  worker: {model: fake, effort: medium}\n  expert: {model: fake, effort: medium}\nouter_resumptions: 2\nverification_retries: 2\n"

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
end
