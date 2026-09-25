Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.LifecycleTest do
  @moduledoc """
  The fake full lifecycle test required by `make check`: public Shape creates
  a Draft, explicit fixture approval moves that exact package to Approved,
  and public Build drives it through a failing Stop Check, independent Review
  rework, exact Developer resume, fresh accept, and Commit. It runs only the
  fake `codex` executable in a disposable fixture.
  The fixture's `check` target is deliberately small: it detects the broken
  source that the fake Developer first creates, then passes after that same
  Developer corrects it. The tracked Stop hook still owns both invocations.
  """
  use ExUnit.Case, async: true

  @moduletag :lifecycle
  @moduletag timeout: 300_000

  @slug "fake-shaped-intent"

  test "public Shape, explicit fixture approval, and public Build form one offline lifecycle" do
    src = File.cwd!()
    dest = Kogen.CompiledFixture.create!(src, "lifecycle")

    on_exit(fn -> File.rm_rf(dest) end)

    install_distinct_profiles!(dest)
    install_target_evidence_fixture!(dest)
    Kogen.VerificationFixture.install!(dest)
    init_fixture_git!(dest)
    original_parent = git!(dest, ["rev-parse", "HEAD"])
    {intent_id, original_intent, original_scenarios} = shape_and_explicitly_approve!(dest)

    bulk_sentinel = "ROLE_CONTEXT_BULK_SENTINEL"

    File.write!(
      Path.join(dest, ".kogen/intents/approved/#{@slug}/supporting-evidence.txt"),
      String.duplicate(bulk_sentinel, 50_000)
    )

    assert_delegation_prompt!(
      File.read!(Path.join(dest, ".kogen/runtime/shaping-prompt")),
      :shaping
    )

    assert git!(dest, ["status", "--porcelain"]) == ""

    fake_harness = Path.join(dest, "test/support/fake_codex")
    shim_dir = Path.join(dest, "test/support")
    raw_log_dir = Path.join(dest, ".kogen/runtime/fake-lifecycle-receipts")

    env = [
      {"KOGEN_HARNESS", fake_harness},
      {"KOGEN_RAW_LOG_DIR", raw_log_dir},
      {"KOGEN_SCENARIO_EVIDENCE_PATH",
       ".kogen/intents/approved/#{@slug}/supporting-evidence.txt"},
      {"PATH", shim_dir <> ":" <> System.get_env("PATH", "")}
    ]

    {output, exit_code} = Kogen.CompiledFixture.mix_task!(dest, ["kogen.build", @slug], env)

    assert exit_code == 0, "mix kogen.build failed:\n#{output}"

    refute File.exists?(Path.join(dest, ".kogen/runtime/path-shim-invoked")),
           "a codex binary other than the fake harness was executed"

    complete_dir = Path.join(dest, ".kogen/intents/complete/#{@slug}")
    approved_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")

    assert File.dir?(complete_dir)
    refute File.dir?(approved_dir)
    assert File.read!(Path.join(complete_dir, "intent.yaml")) == original_intent
    assert File.read!(Path.join(complete_dir, "scenarios.yaml")) == original_scenarios
    assert git!(dest, ["show", "HEAD:dummy.txt"]) == "reviewed fixture value"

    assert git!(dest, ["show", "HEAD:reviewer-rework-marker.txt"]) ==
             "Reviewer-directed rework applied"

    evidence = File.read!(Path.join(complete_dir, "evidence.md"))
    assert evidence =~ "Outer resumptions used: 1"
    assert evidence =~ "Reviewer verdict: accept"

    subject = git!(dest, ["log", "-1", "--format=%s"])
    assert subject == "Fake shaped intent"

    assert raw_commit_message!(dest) ==
             "Fake shaped intent\n\nKogen-Intent-ID: #{intent_id}\nKogen-Intent: #{@slug}\n"

    assert git!(dest, ["rev-parse", "HEAD^"]) == original_parent

    {trailer_out, 0} =
      System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"],
        cd: dest
      )

    assert trailer_out =~ "Kogen-Intent-ID: #{intent_id}"
    assert trailer_out =~ "Kogen-Intent: #{@slug}"

    log_lines =
      Path.join(dest, ".kogen/runtime/fake-harness-log")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(log_lines) == 4
    # Only the two Reviewers own an output schema; Developer turns carry none.
    assert Enum.count(log_lines, &String.contains?(&1, "--output-schema")) == 2
    assert Enum.count(log_lines, &String.contains?(&1, "--output-last-message")) == 2
    assert File.read!(Path.join(dest, ".kogen/runtime/fake-reviewer-calls")) == "2\n"
    assert Enum.count(log_lines, &String.contains?(&1, "exec resume")) == 1

    assert Enum.any?(log_lines, fn line ->
             String.contains?(line, "exec resume ") and
               String.ends_with?(line, " dev-session-1 -")
           end)

    resume_lines = Enum.filter(log_lines, &String.contains?(&1, "exec resume "))
    assert length(resume_lines) == 1
    assert Enum.all?(resume_lines, &String.ends_with?(&1, " dev-session-1 -"))

    resume_feedback = File.read!(Path.join(dest, ".kogen/runtime/developer-resume-prompts"))

    resumed_prompts =
      resume_feedback
      |> String.split("# Developer Role", trim: true)
      |> Enum.map(&("# Developer Role" <> &1))

    assert length(resumed_prompts) == 1
    Enum.each(resumed_prompts, &assert_delegation_prompt!(&1, :developer))
    assert resume_feedback =~ "# Developer Role"
    assert resume_feedback =~ "## Final Developer notes"
    assert resume_feedback =~ "End your turn with a short free-prose final message"
    refute resume_feedback =~ ~s("attempt_token": "<the supplied token>")
    refute resume_feedback =~ "Controller handoff schema"

    assert resume_feedback =~ "category: review_rework"
    assert resume_feedback =~ "record: "
    refute resume_feedback =~ ~s("verdict":"rework")
    refute resume_feedback =~ bulk_sentinel

    tracking_path =
      Path.wildcard(Path.join(dest, ".kogen/runtime/scenario-tracking/*/record.json"))
      |> List.first()

    tracking = tracking_path |> File.read!() |> Jason.decode!()
    assert tracking["status"] == "accepted"
    assert File.stat!(tracking_path).size > 1_048_576
    assert Enum.any?(tracking["findings"], &(&1["status"] == "closed"))

    assert Enum.any?(
             tracking["attempts"],
             &String.starts_with?(&1["failure"], "Reviewer findings:")
           )

    [initial_attempt, accepted_attempt] = tracking["attempts"]

    assert Enum.uniq(Enum.map(tracking["attempts"], & &1["developer_session_id"])) == [
             "dev-session-1"
           ]

    refute initial_attempt["reviewer_session"] == accepted_attempt["reviewer_session"]

    # Each fresh Reviewer starts from a bounded packet bound to its attempt,
    # though the record itself is over 1 MiB.
    for {attempt, n} <- [{initial_attempt, 1}, {accepted_attempt, 2}] do
      binding = attempt["review_packet"]
      packet_bytes = File.read!(Path.join(dest, binding["path"]))
      assert byte_size(packet_bytes) <= 65_536
      assert binding["byte_count"] == byte_size(packet_bytes)
      assert binding["sha256"] == Base.encode16(:crypto.hash(:sha256, packet_bytes), case: :lower)
      packet = Jason.decode!(packet_bytes)
      assert packet["attempt_token"] == attempt["attempt_token"]
      assert packet["candidate_id"] == attempt["candidate_id"]

      prompt = File.read!(Path.join(dest, ".kogen/runtime/reviewer-prompt-#{n}"))
      [_before, context_line | _] = String.split(prompt, "KOGEN_TASK_CONTEXT\n")
      context = context_line |> String.split("\n") |> hd() |> Jason.decode!()
      assert context["evidence_source"] == "review_packet"
      assert context["review_packet"] == Map.take(binding, ["path", "sha256", "byte_count"])
      assert context["tracking_path"] == Path.relative_to(tracking_path, dest)
    end

    invalid_receipt =
      initial_attempt["verification"]["cycles"]
      |> Enum.flat_map(& &1["receipts"])
      |> Enum.find(&(&1["status"] == "failed" and &1["target"] == "target_evidence"))

    assert invalid_receipt["output"] =~ "duplicate evidence manifest frames"

    for {attempt, expected} <- [
          {initial_attempt, "behavior still violates scenario\n"},
          {accepted_attempt, "reviewed behavior\n"}
        ] do
      receipt = List.first(attempt["targets"])
      assert receipt["target"] == "target_evidence"
      refute receipt["output"] =~ "PRIVATE_TARGET_SENTINEL"
      retained = receipt["target_evidence"]
      assert retained["attempt_token"] == attempt["attempt_token"]
      semantic = List.first(retained["required_evidence"])
      assert Base.decode64!(semantic["content_base64"]) == expected

      assert semantic["sha256"] ==
               Base.encode16(:crypto.hash(:sha256, expected), case: :lower)
    end

    assert Map.has_key?(
             initial_attempt["reviewer_reference_snapshots"],
             ".kogen/runtime/target-evidence/2-initial/semantic.txt"
           )

    accepted_refs = accepted_attempt["reviewer_reference_snapshots"]
    assert Map.has_key?(accepted_refs, ".kogen/runtime/target-evidence/3-reviewed/semantic.txt")
    refute Map.has_key?(accepted_refs, ".kogen/runtime/target-evidence/3-reviewed/uncited.bin")

    uncited =
      accepted_attempt["targets"]
      |> List.first()
      |> get_in(["target_evidence", "required_evidence"])
      |> Enum.find(&String.ends_with?(&1["path"], "uncited.bin"))

    assert byte_size(Base.decode64!(uncited["content_base64"])) > 5_242_880

    refute git!(dest, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]) =~
             ".kogen/runtime/"

    refute resume_feedback =~ "settled Check failure:",
           "a failed Check settlement would consume a second outer resumption"

    assert Enum.at(log_lines, 0) =~ "--model fixture-developer"
    assert Enum.at(log_lines, 0) =~ "model_reasoning_effort=\"developer-effort\""
    assert Enum.at(log_lines, 1) =~ "--model fixture-reviewer"
    assert Enum.at(log_lines, 1) =~ "model_reasoning_effort=\"reviewer-effort\""
    assert Enum.at(log_lines, 2) =~ "--model fixture-developer"
    assert Enum.at(log_lines, 2) =~ "model_reasoning_effort=\"developer-effort\""
    assert Enum.at(log_lines, 3) =~ "--model fixture-reviewer"
    assert Enum.at(log_lines, 3) =~ "model_reasoning_effort=\"reviewer-effort\""

    assert_delegation_prompt!(
      File.read!(Path.join(dest, ".kogen/runtime/developer-launch-prompt")),
      :developer
    )

    refute File.read!(Path.join(dest, ".kogen/runtime/developer-launch-prompt")) =~ bulk_sentinel

    assert_delegation_prompt!(
      File.read!(Path.join(dest, ".kogen/runtime/reviewer-prompt-1")),
      :reviewer
    )

    refute File.read!(Path.join(dest, ".kogen/runtime/reviewer-prompt-1")) =~ bulk_sentinel
    refute File.read!(Path.join(dest, ".kogen/runtime/reviewer-prompt-2")) =~ bulk_sentinel

    check_histories =
      (verification_history_archives(raw_log_dir) ++
         [Path.join(dest, ".kogen/runtime/verification-history.jsonl")])
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        path
        |> File.stream!()
        |> Enum.map(&(String.trim(&1) |> Jason.decode!()))
        |> Enum.filter(&(&1["session_id"] == "dev-session-1"))
      end)

    initial_history =
      Enum.find(check_histories, fn records ->
        Enum.any?(records, &String.contains?(&1["reason"] || "", "lib/kogen_fake_break.ex"))
      end)

    assert is_list(initial_history), "the initial Developer Check history must be retained"

    failed_check_index = Enum.find_index(initial_history, &(&1["status"] == "failed"))
    passed_check_index = Enum.find_index(initial_history, &(&1["status"] == "passed"))

    assert is_integer(failed_check_index), "the initial Developer Stop must record a failed Check"
    assert is_integer(passed_check_index), "the same Developer must later record a passed Check"

    assert failed_check_index < passed_check_index,
           "the failed Stop Check must precede the passing Check in one Developer thread"

    failed_reason = initial_history |> Enum.at(failed_check_index) |> Map.fetch!("reason")

    assert failed_reason =~ "lib/kogen_fake_break.ex",
           "the retained failed settlement reason must identify the bounded fixture check"
  end

  # Scenario "hybrid-route-launches-dominant-and-adversarial": a Build on a
  # role-level (hybrid) route launches the Developer only on its dominant
  # harness (Claude Code) and the Reviewer only on the adversarial harness
  # (Codex), resumes the exact Developer session on Claude Code after one
  # Reviewer-requested rework round, never lets Stop ownership move to the
  # Reviewer, and keeps the originally resolved role-to-harness matrix even
  # after `.kogen/config.yaml` is edited mid-Build.
  @hybrid_slug "hybrid-route-intent"

  @hybrid_intent_yaml """
  id: 01960000-0000-7000-8000-0000000hyb01
  slug: #{@hybrid_slug}
  title: Hybrid route intent
  may_change_guarded_paths:
    - dummy.txt
    - reviewer-rework-marker.txt
    - .kogen/config.yaml
  """

  @hybrid_scenarios_yaml """
  - id: hybrid-route-scenario
    given: a fake Candidate
    when: the hybrid Reviewer reworks once on Codex then accepts
    then: the Developer stays on Claude Code and the Reviewer stays on Codex, with the frozen route held across a mid-Build config edit
    wrong_result: a later launch or the recorded route reflects the mid-Build edit, or Stop runs for the Reviewer
    verified_by: [check]
    evidence: fake hybrid dispatcher scripted to rework once then accept, with a mid-Build config mutation
    proof:
      offline: [hybrid-proof.txt]
      paid_target: none
      paid_reason: "offline-sufficient: scripted lifecycle fixture observes hybrid role dispatch"
      affected_paths: [dummy.txt, reviewer-rework-marker.txt]
  """

  @hybrid_config_before """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: codex, model: gpt-6-sol, effort: high}
      expert:    {harness: codex, model: gpt-6-sol, effort: high}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
        codex:
          scout:  {model: gpt-6-luna, effort: low}
          worker: {model: gpt-6-luna, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  # Fired once, from within the fake dispatcher, on the Developer's fresh
  # Claude Code launch: moves the Reviewer onto Claude too and changes the
  # Expert and every native helper profile. If the Build ever re-read config,
  # a later launch would observe the edit.
  @hybrid_config_mutated """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: claude, model: claude-opus-5-5, effort: medium}
      expert:    {harness: codex, model: gpt-6-mutated, effort: low}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: medium}
          worker: {model: claude-sonnet-5, effort: low}
        codex:
          scout:  {model: gpt-6-mutated-luna, effort: high}
          worker: {model: gpt-6-mutated-luna, effort: low}
  outer_resumptions: 2
  verification_retries: 2
  """

  @frozen_expert_assignment %{
    "route" => "hybrid",
    "caller" => "developer",
    "harness" => "codex",
    "model" => "gpt-6-sol",
    "effort" => "high",
    "helpers" => %{
      "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
      "worker" => %{"model" => "gpt-6-luna", "effort" => "high"}
    }
  }

  @frozen_role_assignment %{
    "shaping" => %{"harness" => "claude", "model" => "claude-opus-5-5", "effort" => "medium"},
    "developer" => %{"harness" => "claude", "model" => "claude-opus-5-5", "effort" => "medium"},
    "reviewer" => %{"harness" => "codex", "model" => "gpt-6-sol", "effort" => "high"},
    "expert" => %{"harness" => "codex", "model" => "gpt-6-sol", "effort" => "high"},
    "helpers" => %{
      "claude" => %{
        "scout" => %{"model" => "claude-sonnet-5", "effort" => "low"},
        "worker" => %{"model" => "claude-sonnet-5", "effort" => "medium"}
      },
      "codex" => %{
        "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
        "worker" => %{"model" => "gpt-6-luna", "effort" => "high"},
        "expert" => %{"model" => "gpt-6-sol", "effort" => "high"}
      }
    }
  }

  test "a hybrid route launches the Developer on Claude Code and Review on Codex, resumes exactly, and freezes the role matrix" do
    project_root = File.cwd!()
    dest = Kogen.CompiledFixture.create!(project_root, "hybrid-lifecycle")
    on_exit(fn -> File.rm_rf(dest) end)

    install_hybrid_fixture_files!(project_root, dest)

    File.write!(Path.join(dest, ".kogen/config.yaml"), @hybrid_config_before)

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@hybrid_slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @hybrid_intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @hybrid_scenarios_yaml)

    init_fixture_git!(dest)
    head_before = git!(dest, ["rev-parse", "HEAD"])

    hook_dir =
      Path.join(System.tmp_dir!(), "kogen-hybrid-hook-#{System.unique_integer([:positive])}")

    File.mkdir_p!(hook_dir)
    on_exit(fn -> File.rm_rf(hook_dir) end)
    mutated_config = Path.join(hook_dir, "mutated.yaml")
    File.write!(mutated_config, @hybrid_config_mutated)

    fake_harness = Path.join(dest, "test/support/fake_hybrid")
    claude_root = Path.join(dest <> "-claude", "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

    # Every fixture switch travels as an explicit env entry to this one
    # subprocess (via `Kogen.CompiledFixture.mix_task!`), never as a
    # `System.put_env` mutation of the shared outer test VM: this file's
    # tests run alongside other async test modules (some of which spawn their
    # own isolated child VMs that inherit the outer VM's ambient OS
    # environment at spawn time), so a global env mutation here could leak
    # into an unrelated concurrently-running Build fixture.
    build_env = [
      {"KOGEN_HARNESS", fake_harness},
      {"KOGEN_CLAUDE_ROOT", claude_root},
      {"FAKE_CLAUDE_STOP_BLOCK", "0"},
      {"FAKE_CLAUDE_RESUME_EDITS", "1"},
      {"FAKE_HYBRID_MIDBUILD_CONFIG", mutated_config}
    ]

    {output, exit_code} =
      Kogen.CompiledFixture.mix_task!(
        dest,
        ["kogen.build", "--route", "hybrid", @hybrid_slug],
        build_env
      )

    assert exit_code == 0, "expected the hybrid Build to accept:\n#{output}"

    assert File.read!(Path.join(dest, ".kogen/config.yaml")) == @hybrid_config_mutated,
           "sanity: the mid-Build config mutation really happened"

    dispatch_lines =
      Path.join(dest, ".kogen/runtime/hybrid-dispatch-log")
      |> File.read!()
      |> String.split("\n", trim: true)

    # Categorized by protocol (`-p` vs `exec`), not by the dispatcher's logged
    # `role=`: an ambient `KOGEN_ROLE` inherited from an enclosing ordinary
    # shell environment (never set by Kogen code for readiness checks) could
    # otherwise mislabel the unrelated `claude auth status` readiness call.
    developer_lines = Enum.filter(dispatch_lines, &String.contains?(&1, "argv: -p"))
    reviewer_lines = Enum.filter(dispatch_lines, &String.contains?(&1, "argv: exec"))

    assert length(developer_lines) == 2, "expected exactly a fresh and a resumed Developer turn"

    assert length(reviewer_lines) == 2,
           "expected exactly a rework then an accepting Reviewer turn"

    for line <- developer_lines do
      assert line =~ "argv: -p", "the Developer must always run the Claude protocol"
      assert line =~ "--model claude-opus-5-5"
      assert line =~ "--effort medium"
      assert line =~ "--dangerously-skip-permissions"
      refute line =~ "argv: exec", "the Developer must never run under the Codex protocol"

      assert expert_assignment!(line) == @frozen_expert_assignment,
             "the Developer must carry the frozen cross-harness Expert assignment: #{line}"

      # The Developer's native Claude Code helpers keep their frozen profiles
      # and no native expert stands in for the Codex Expert.
      assert line =~
               ~r/"kogen-scout":\{"description":"[^"]*","effort":"low","model":"claude-sonnet-5"/

      assert line =~
               ~r/"kogen-worker":\{"description":"[^"]*","effort":"medium","model":"claude-sonnet-5"/

      refute line =~ "kogen-expert"
    end

    for line <- reviewer_lines do
      assert line =~ "argv: exec", "the Reviewer must always run the Codex protocol"
      assert line =~ "--model gpt-6-sol"
      assert line =~ ~s(model_reasoning_effort=\"high\")
      assert line =~ "--dangerously-bypass-approvals-and-sandbox"
      assert line =~ "--output-schema"
      refute line =~ "argv: -p", "the Reviewer must never run under the Claude Code protocol"
      assert line =~ "role=reviewer"

      assert line =~ "expert= argv:",
             "the Reviewer's own Expert is native Codex, so it must carry no KOGEN_EXPERT"
    end

    # The adversarial Codex Reviewer gets the same bounded review packet the
    # dominant harness's Reviewer would get, bound to its attempt.
    for n <- 1..2 do
      prompt = File.read!(Path.join(dest, ".kogen/runtime/reviewer-prompt-#{n}"))
      [_prompt, context] = String.split(prompt, "KOGEN_TASK_CONTEXT\n", parts: 2)
      context = context |> String.split("\n", parts: 2) |> hd() |> Jason.decode!()
      assert context["evidence_source"] == "review_packet"
      packet = Path.join(dest, context["review_packet"]["path"])
      assert packet =~ "/review-packets/#{n - 1}.json"
      assert File.exists?(packet)
    end

    [fresh_line, resumed_line] = developer_lines

    [_before, session_id] = String.split(fresh_line, "--session-id ", parts: 2)
    session_id = session_id |> String.split(" ") |> List.first()

    assert resumed_line =~ "--resume #{session_id}",
           "the resumed Developer turn must reuse the exact fresh session id"

    refute fresh_line =~ "--resume", "the fresh Developer launch must never carry --resume"

    hook_responses =
      Path.join(dest, ".kogen/runtime/fake-hook-responses")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(hook_responses) == 2,
           "Stop must run exactly once per Developer turn (fresh and resumed), never for the Reviewer"

    assert File.read!(Path.join(dest, "dummy.txt")) == "reviewed fixture value\n"

    assert File.read!(Path.join(dest, "reviewer-rework-marker.txt")) ==
             "Reviewer-directed rework applied\n"

    head_after = git!(dest, ["rev-parse", "HEAD"])
    refute head_after == head_before, "the accepted hybrid Build must have committed"

    complete_dir = Path.join(dest, ".kogen/intents/complete/#{@hybrid_slug}")
    assert File.dir?(complete_dir)

    [record_path] =
      Path.wildcard(Path.join(dest, ".kogen/runtime/scenario-tracking/*/record.json"))

    record = record_path |> File.read!() |> Jason.decode!()

    # The existing route map keeps its exact shape; the matrix is additive.
    assert record["route"] == %{
             "name" => "hybrid",
             "harness" => "claude",
             "shaping" => %{"model" => "claude-opus-5-5", "effort" => "medium"},
             "developer" => %{"model" => "claude-opus-5-5", "effort" => "medium"},
             "reviewer" => %{"model" => "gpt-6-sol", "effort" => "high"},
             "helpers" => %{
               "scout" => %{"model" => "claude-sonnet-5", "effort" => "low"},
               "worker" => %{"model" => "claude-sonnet-5", "effort" => "medium"}
             }
           }

    assert record["role_assignment"] == @frozen_role_assignment,
           "the tracking record must hold the originally resolved matrix, never the mid-Build edit"

    assert record["role_assignment"] |> Map.keys() |> Enum.sort() ==
             ["developer", "expert", "helpers", "reviewer", "shaping"]

    # Every role view derived for a launch after the edit comes from the
    # frozen role_assignment: the Expert assignment and each harness's native
    # helper profiles.
    {:ok, mutated} = File.cd!(dest, fn -> Kogen.Intent.read_config(".kogen/config.yaml") end)
    refute Map.has_key?(mutated, :auditor)
    refute Map.has_key?(mutated.roles, :auditor)
    frozen = Kogen.Build.assigned_config(mutated, record)

    assert frozen.roles == %{
             shaping: "claude",
             developer: "claude",
             reviewer: "codex",
             expert: "codex"
           }

    refute Map.has_key?(frozen, :auditor)
    refute Map.has_key?(frozen.roles, :auditor)

    [{"KOGEN_EXPERT", json}] = Kogen.Harness.expert_environment(frozen, :developer)
    assert Jason.decode!(json) == @frozen_expert_assignment

    assert Kogen.Intent.role_config(frozen, :developer).helpers == %{
             scout: %{model: "claude-sonnet-5", effort: "low"},
             worker: %{model: "claude-sonnet-5", effort: "medium"}
           }

    [initial_attempt, accepted_attempt] = record["attempts"]

    assert Enum.uniq(Enum.map(record["attempts"], & &1["developer_session_id"])) == [session_id]

    refute initial_attempt["reviewer_session"] == accepted_attempt["reviewer_session"],
           "each Reviewer launch must be an independent Codex session, distinct from the Developer's"

    refute accepted_attempt["reviewer_session"] == session_id
    refute initial_attempt["reviewer_session"] == session_id

    summary =
      complete_dir |> Path.join("build-summary.json") |> File.read!() |> Jason.decode!()

    assert summary["route"] == %{"name" => "hybrid", "harness" => "claude"}
    assert summary["role_assignment"] == @frozen_role_assignment

    evidence = File.read!(Path.join(complete_dir, "evidence.md"))
    assert evidence =~ "Route: `hybrid` (harness `claude`)"
    assert evidence =~ "developer `claude`"
    assert evidence =~ "reviewer `codex`"
  end

  # A role failure names the role's frozen harness, model and effort, even
  # after a mid-Build edit moved that role to another harness and profile.
  test "a failing hybrid Reviewer's stop reason names its frozen harness, model and effort" do
    project_root = File.cwd!()
    dest = Kogen.CompiledFixture.create!(project_root, "hybrid-failure")
    on_exit(fn -> File.rm_rf(dest) end)

    install_hybrid_fixture_files!(project_root, dest)
    File.write!(Path.join(dest, ".kogen/config.yaml"), @hybrid_config_before)
    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@hybrid_slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), @hybrid_intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), @hybrid_scenarios_yaml)
    init_fixture_git!(dest)

    hook_dir =
      Path.join(System.tmp_dir!(), "kogen-hybrid-fail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(hook_dir)
    on_exit(fn -> File.rm_rf(hook_dir) end)
    mutated_config = Path.join(hook_dir, "mutated.yaml")
    File.write!(mutated_config, @hybrid_config_mutated)
    claude_root = Path.join(dest <> "-claude", "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

    {output, exit_code} =
      Kogen.CompiledFixture.mix_task!(dest, ["kogen.build", "--route", "hybrid", @hybrid_slug], [
        {"KOGEN_HARNESS", Path.join(dest, "test/support/fake_hybrid")},
        {"KOGEN_CLAUDE_ROOT", claude_root},
        {"FAKE_CLAUDE_STOP_BLOCK", "0"},
        {"FAKE_HYBRID_MIDBUILD_CONFIG", mutated_config},
        {"FAKE_HYBRID_REVIEWER_MALFORMED", "1"}
      ])

    assert exit_code != 0
    assert File.read!(Path.join(dest, ".kogen/config.yaml")) == @hybrid_config_mutated
    assert output =~ "Reviewer failure: "
    assert output =~ "(reviewer on harness codex, gpt-6-sol at high)"
    refute output =~ "reviewer on harness claude"
    refute File.dir?(Path.join(dest, ".kogen/intents/complete/#{@hybrid_slug}"))
  end

  defp expert_assignment!(dispatch_line) do
    [_before, rest] = String.split(dispatch_line, "expert=", parts: 2)
    [json, _after] = String.split(rest, " argv:", parts: 2)
    Jason.decode!(json)
  end

  # `Kogen.CompiledFixture.create!/2` already installs the tracked Stop hooks,
  # role prompts, `.gitignore`, a trivial-passing Makefile and every fixture
  # executable a plain Codex or Claude Code route needs (including
  # `fake_claude` and its `scenario_response.py`/`claude_stream.py`
  # dependencies). Only the hybrid dispatcher and this route's minimal
  # verification catalog and offline proof selector are added here.
  defp install_hybrid_fixture_files!(project_root, dest) do
    File.cp!(
      Path.join(project_root, "test/support/fake_hybrid"),
      Path.join(dest, "test/support/fake_hybrid")
    )

    File.chmod!(Path.join(dest, "test/support/fake_hybrid"), 0o755)

    File.write!(Path.join(dest, "hybrid-proof.txt"), "hybrid route fixture selector\n")
    File.mkdir_p!(Path.join(dest, "priv/kogen"))

    File.write!(Path.join(dest, "priv/kogen/verification_targets.yaml"), """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)
  end

  defp init_fixture_git!(dest) do
    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)
  end

  defp install_distinct_profiles!(dest) do
    File.write!(Path.join(dest, ".kogen/config.yaml"), """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping: {model: fixture-shaper, effort: shaping-effort}
        developer: {model: fixture-developer, effort: developer-effort}
        reviewer: {model: fixture-reviewer, effort: reviewer-effort}
        helpers:
          scout: {model: fixture-scout, effort: scout-effort}
          worker: {model: fixture-worker, effort: worker-effort}
          expert: {model: fixture-expert, effort: expert-effort}
    outer_resumptions: 2
    verification_retries: 2
    """)
  end

  defp install_target_evidence_fixture!(dest) do
    source = File.cwd!()

    for relative <- [
          "test/test_helper.exs",
          "test/support/isolated_case.ex",
          "test/support/isolated_process.py",
          "test/support/timing_formatter.ex"
        ] do
      destination = Path.join(dest, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(source, relative), destination)
    end

    File.write!(Path.join(dest, "test/support/target_evidence_lifecycle_producer.exs"), ~S'''
    defmodule Kogen.TargetEvidenceLifecycleProducer do
      use Kogen.IsolatedCase, async: true, target_evidence: :required

      test "publishes retained scenario evidence through isolation" do
        counter_path = ".kogen/runtime/target-evidence-invocations"
        invocation = if File.exists?(counter_path), do: File.read!(counter_path) |> String.to_integer(), else: 0
        invocation = invocation + 1
        File.write!(counter_path, Integer.to_string(invocation))
        reviewed? = File.read!("dummy.txt") == "reviewed fixture value\n"
        state = cond do
          invocation == 1 -> "invalid"
          reviewed? -> "reviewed"
          true -> "initial"
        end
        run = "#{invocation}-#{state}"
        semantic = if reviewed?, do: "reviewed behavior\n", else: "behavior still violates scenario\n"
        root = Path.join(".kogen/runtime/target-evidence", run)
        File.mkdir_p!(root)
        File.write!(Path.join(root, "semantic.txt"), semantic, [:exclusive])
        uncited = :binary.copy(<<0, 7, 255>>, 1_747_627)
        File.write!(Path.join(root, "uncited.bin"), uncited, [:exclusive])

        required =
          for {name, bytes} <- [{"semantic.txt", semantic}, {"uncited.bin", uncited}] do
            %{"path" => Path.join(root, name), "sha256" => sha256(bytes)}
          end

        manifest_path = Path.join(root, "manifest.json")
        entries =
          Enum.map_join(required, ",", fn entry ->
            ~s({"path":"#{entry["path"]}","sha256":"#{entry["sha256"]}"})
          end)
        manifest = ~s({"schema_version":1,"required_evidence":[#{entries}]})
        File.write!(manifest_path, manifest, [:exclusive])
        locator = ~s({"manifest_path":"#{manifest_path}","sha256":"#{sha256(manifest)}"})
        IO.write("progress without newline")
        if invocation == 1, do: IO.puts("KOGEN_TARGET_EVIDENCE_MANIFEST\t{malformed}")
        IO.puts("KOGEN_TARGET_EVIDENCE_MANIFEST\t" <> locator)
        IO.write(String.duplicate("PRIVATE_TARGET_SENTINEL", 500))
      end

      defp sha256(bytes),
        do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    end
    ''')

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute and Path.basename(&1) == "ebin"))
      |> Enum.uniq()
      |> Enum.map_join(" ", &("-pa " <> &1))

    File.write!(
      Path.join(dest, "Makefile"),
      File.read!(Path.join(dest, "Makefile")) <>
        "\ntarget_evidence:\n\t@KOGEN_TEST_ROOT=$$(pwd) elixir --erl \"+S 2:2 +SDcpu 1 +SDio 1\" #{code_paths} -S mix test test/support/target_evidence_lifecycle_producer.exs --no-start --no-deps-check --no-compile\n"
    )
  end

  defp shape_and_explicitly_approve!(dest) do
    env = [{"KOGEN_HARNESS", Path.join(dest, "test/support/fake_codex_shaper")}]

    {output, 0} = Kogen.CompiledFixture.mix_task!(dest, "kogen.shape", env)

    [intent_id] =
      Regex.run(~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/, output)

    draft_dir = Path.join(dest, ".kogen/intents/drafts/#{@slug}")
    approved_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    assert File.dir?(draft_dir), "public Shape did not persist the fixture Draft"

    original_intent = File.read!(Path.join(draft_dir, "intent.yaml"))
    original_scenarios = File.read!(Path.join(draft_dir, "scenarios.yaml"))
    assert original_intent =~ intent_id
    shaped = YamlElixir.read_from_string!(original_intent)

    assert shaped["shaped_against"] == %{
             "branch" => git!(dest, ["branch", "--show-current"]),
             "head" => git!(dest, ["rev-parse", "HEAD"])
           }

    {:ok, config} = Kogen.Intent.read_config(Path.join(dest, ".kogen/config.yaml"))
    assert shaped["shaping"]["model"] == config.shaping.model
    assert shaped["shaping"]["effort"] == config.shaping.effort

    shaping_args = File.read!(Path.join(dest, ".kogen/runtime/shaping-args"))
    assert shaping_args =~ "--model\nfixture-shaper\n"
    assert shaping_args =~ ~s(model_reasoning_effort="shaping-effort")

    # This rename is the fixture's explicit same-conversation approval. The
    # fake Shaping Controller itself deliberately writes only a Draft.
    File.mkdir_p!(Path.dirname(approved_dir))
    File.rename!(draft_dir, approved_dir)

    refute File.dir?(draft_dir)
    assert File.dir?(approved_dir)

    {intent_id, original_intent, original_scenarios}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end

  defp assert_delegation_prompt!(prompt, role) do
    refute prompt =~ "{{"
    prompt = String.replace(prompt, ~r/\s+/, " ")

    assert length(String.split(prompt, "## Shared execution and delegation policy")) == 2

    assert prompt =~
             "Configured root (#{role}): `fixture-#{root_name(role)}` at `#{root_effort(role)}`."

    assert prompt =~ "**scout:** `fixture-scout` at `scout-effort`; native kind `explorer`."
    assert prompt =~ "**worker:** `fixture-worker` at `worker-effort`; native kind `worker`."
    assert prompt =~ "**expert:** `fixture-expert` at `expert-effort`; native kind `default`."
    assert prompt =~ "small sufficient packet"
    assert prompt =~ "fresh or minimal context"
    assert prompt =~ "automatic escalation chain"
    assert prompt =~ "Report native unavailability and execution failures"

    case role do
      :shaping ->
        assert prompt =~ "The human retains product and scope decisions"
        assert prompt =~ "You retain Draft authorship and approval handling"
        assert prompt =~ "continue accepting steering while helpers work"

      :developer ->
        assert prompt =~ "non-overlapping paths within `may_change_guarded_paths`"
        assert prompt =~ "No helper may edit either of those protected inputs"
        assert prompt =~ "Wait for every child before Candidate capture"
        assert prompt =~ "run or delegate a declared verification gate"
        assert prompt =~ "exact Developer session"

      :reviewer ->
        assert prompt =~ "Reviewer and every child are read-only, preserve the Candidate"
        assert prompt =~ "receive no Developer conversation as evidence"
        assert prompt =~ "Wait for every child before deciding"
        assert prompt =~ "schema-valid final verdict yourself"
    end
  end

  defp root_name(:shaping), do: "shaper"
  defp root_name(:developer), do: "developer"
  defp root_name(:reviewer), do: "reviewer"

  defp root_effort(:shaping), do: "shaping-effort"
  defp root_effort(:developer), do: "developer-effort"
  defp root_effort(:reviewer), do: "reviewer-effort"

  defp raw_commit_message!(dir) do
    {commit, 0} = System.cmd("git", ["cat-file", "commit", "HEAD"], cd: dir)
    [_headers, message] = String.split(commit, "\n\n", parts: 2)
    message
  end

  defp verification_history_archives(raw_log_dir) do
    raw_log_dir
    |> Path.join("verification-history-*.jsonl")
    |> Path.wildcard()
  end
end
