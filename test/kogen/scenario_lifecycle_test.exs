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

  test "target failure preserves cumulative findings through the last allowed rework" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, reason} = run(dir, "target_history")
    assert reason =~ "stopped after 2 outer resumptions"

    record = record!(dir)
    assert Enum.map(record["findings"], & &1["id"]) == ["F1", "F2"]
    assert Enum.all?(record["findings"], &(&1["status"] == "open"))

    assert Enum.any?(
             record["attempts"],
             &String.contains?(&1["failure"] || "", "declared-target failure")
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

    [closure] =
      Path.wildcard(
        Path.join(complete, ".kogen/intents/complete/#{@slug}/scenario-tracking*.json")
      )

    closure_record = Jason.decode!(File.read!(closure))
    assert closure_record["status"] == "accepted"

    assert File.read!(Path.join(complete, ".kogen/intents/complete/#{@slug}/evidence.md")) =~
             Path.basename(closure)
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

    closure =
      Path.join(dir, ".kogen/intents/complete/#{@slug}/scenario-tracking.json")
      |> File.read!()
      |> Jason.decode!()

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

    complete = Path.join(dir, ".kogen/intents/complete/#{@slug}/scenario-tracking.json")
    assert Jason.decode!(File.read!(complete)) == record
  end

  test "citing the record never permits a Reviewer to change it" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:error, reason} = run(dir, "record_citation_tamper")
    assert reason =~ "scenario tracking record changed outside Build"
    refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
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

    for path <- [
          ".codex/hooks/check.sh",
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
      "check:\n\t@true\nverify:\n\t@test ! -f .kogen/runtime/fail-target\n"
    )

    File.write!(Path.join(dir, "dummy.txt"), "baseline\n")
    intent = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent)

    File.write!(
      Path.join(intent, "intent.yaml"),
      "id: 01960000-0000-7000-8000-00000000aa11\nslug: #{@slug}\ntitle: Scenario lifecycle\nmay_change_guarded_paths: [dummy.txt]\n"
    )

    File.write!(Path.join(intent, "scenarios.yaml"), scenarios())

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
      "harness: codex\nshaping: {model: fake, effort: low}\ndeveloper: {model: fake, effort: low}\nreviewer: {model: fake, effort: low}\nhelpers:\n  scout: {model: fake, effort: low}\n  worker: {model: fake, effort: medium}\n  expert: {model: fake, effort: medium}\nouter_resumptions: 2\n"

  defp record!(dir), do: records(dir) |> List.last() |> File.read!() |> Jason.decode!()

  defp records(dir),
    do: Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))

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
