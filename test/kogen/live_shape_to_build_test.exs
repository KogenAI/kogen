Code.require_file("../support/live_rework_audit.ex", __DIR__)
Code.require_file("../support/live_native_receipt_audit.ex", __DIR__)
Code.require_file("../support/dependency_fixture.ex", __DIR__)
Code.require_file("../support/root_profile_audit.ex", __DIR__)
Code.require_file("../support/claude_trust.ex", __DIR__)
Code.require_file("../support/live_tracking_retention.ex", __DIR__)
Code.require_file("../support/boundary_probe_fixture.ex", __DIR__)

defmodule Kogen.LiveShapeToBuildTest do
  @moduledoc """
  The real, public, end-to-end lifecycle in a bounded, disposable fixture:
  the headless Shaping engine (`mix kogen.shape`, driven by an external
  driver through its public commands) drafts an Intent, receives explicit scripted test approval (test
  data only -- not approval of a real feature), and the real Builder
  (`mix kogen.build <slug>`) then builds *that exact* shaped-and-approved
  package -- not a separately hand-written Approved package claiming to
  be end-to-end.

  Every transition is enforced against real disk state, not swallowed:
  Draft files must exist before the scripted approval is sent; Approved
  files must exist and Draft must be gone afterward, carrying the same
  minted UUIDv7 identity that was printed at the start; the Shaping Stop hook
  must complete its real audit and launched auditor before the driver closes
  each native session; and the real controller's own Verification Record
  history must show an actual `failed` record followed by an actual `passed`
  record for the *same* Developer session before its first handoff. The value
  the Developer needs to fix the failing target reaches it only through the
  controller's resume message.

  Runs in an isolated, disposable fixture: a fresh clone with its own git
  history, placed in the system temporary directory outside the publishable
  Candidate and removed after the run. Private `deps/` are copied into the
  fixture. Claude Code keys trust on the fixture's own repository root,
  so under `harness: claude` the test pre-trusts only that fixture through
  the documented `hasTrustDialogAccepted` setting in the selected Kogen scope
  and removes the entry afterwards; Kogen itself never answers the dialog.
  Codex trust is applied by the selected managed launch. The test does not
  grade the one-time trust dialog itself. Raw provider streams
  and every intermediate receipt are written directly under this track's
  owned runtime directory as the run proceeds, not copied in afterward,
  so they survive independent of fixture cleanup. The Build-only
  reviewer-directed rework fixture lives in `Kogen.LiveReviewerReworkFixture`
  and does not substitute for this connected proof.
  """
  use ExUnit.Case, async: true
  alias Kogen.Build.{Contract, VerificationPlan, Workspace}
  alias Kogen.Intent

  @moduletag :live
  @moduletag timeout: 1_200_000

  @slug "shape-to-build-probe"
  @uuid_v7 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @shaping_bound_ms 20 * 60_000
  @poll_ms 5_000
  @max_answer_rounds 4

  # `optimum` is the maintained, connected default route: Astra Low Shaping
  # on Codex, Opus Medium Developer on Claude, Sol High Review on Codex, Opus
  # High auditor on Claude. The test also runs unmodified against any other
  # explicitly selected route (`config.route` names whichever one actually
  # resolved), so this constant only pins the public default path's exact
  # expectation, never a stand-in for a generic route's own resolved values.
  @optimum_shaping_profile %{harness: "codex", model: "gpt-6-astra", effort: "low"}

  @check_rule """
  check:
  \t@test -f dummy.txt || (echo "dummy.txt is missing. Required exact content: shape2build-k4q9z" && exit 1)
  \t@grep -qx shape2build-k4q9z dummy.txt || (echo "dummy.txt content is wrong. Required exact content: shape2build-k4q9z" && exit 1)
  """

  test "headless Shape drafts and approves through the engine, then Build completes the same Intent" do
    project_root = Path.expand("../..", __DIR__)
    selected_route = System.get_env("KOGEN_ROUTE")

    {:ok, config} =
      Kogen.Intent.read_config(".kogen/config.yaml", selected_route)

    shaping_harness = Intent.role_harness(config, :shaping)

    if config.route == "optimum" do
      assert shaping_harness == @optimum_shaping_profile.harness
      assert config.shaping.model == @optimum_shaping_profile.model
      assert config.shaping.effort == @optimum_shaping_profile.effort
    end

    log_dir = owned_log_dir(project_root)

    fixture_parent =
      Path.join(
        System.tmp_dir!(),
        "kogen-live-shape2build-fixtures-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_parent)

    fixture =
      Path.join(
        fixture_parent,
        "fixture-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(fixture)
    # Success removes the fixture inside the test; a fixture still present here
    # means the test failed, so its evidence is retained beside the live logs.
    on_exit(fn ->
      retain_failed_fixture!(fixture, log_dir)

      if File.dir?(fixture_parent) and File.ls!(fixture_parent) == [] do
        File.rmdir!(fixture_parent)
      end
    end)

    assert Path.relative_to(fixture, project_root) == fixture,
           "the disposable fixture must live outside the publishable Candidate"

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    shaping_brief_content = shaping_brief()
    setup_fixture(project_root, fixture, shaping_brief_content)

    # This fixture check is a pre-dispatch evidence capture, not a Candidate
    # verification run. Its output stays in the outer run log; the exact source
    # line remains available in the committed fixture materialization.
    {prepaid_check_output, prepaid_check_exit} =
      System.cmd("make", ["check"], cd: fixture, stderr_to_stdout: true)

    assert prepaid_check_exit != 0
    assert prepaid_check_output =~ "Required exact content: shape2build-k4q9z"
    File.write!(Path.join(log_dir, "prepaid-check-output.txt"), prepaid_check_output)

    materialized_audit_package = Path.join(log_dir, "prepaid-audit-materialization")
    File.mkdir_p!(Path.join(materialized_audit_package, "evidence"))
    File.cp!(Path.join(fixture, "Makefile"), Path.join(materialized_audit_package, "Makefile"))

    File.cp!(
      Path.join(fixture, "evidence/brief.md"),
      Path.join(materialized_audit_package, "evidence/brief.md")
    )

    File.write!(
      Path.join(materialized_audit_package, "evidence/prepaid-check-output.txt"),
      prepaid_check_output
    )

    makefile_excerpt =
      File.read!(Path.join(fixture, "Makefile")) |> String.split("\n") |> Enum.at(1)

    brief_excerpt =
      File.read!(Path.join(fixture, "evidence/brief.md")) |> String.split("\n") |> hd()

    prepaid_citations = [
      %{path: "evidence/brief.md", line: 1, excerpt: brief_excerpt},
      %{path: "Makefile", line: 2, excerpt: makefile_excerpt}
    ]

    consumer = Path.join(project_root, "test/support/shaping_evaluation/value_evidence.py")

    {prepaid_consumer_output, prepaid_consumer_status} =
      System.cmd(
        "python3",
        [
          "-B",
          "-c",
          "import importlib.util,sys,json; s=importlib.util.spec_from_file_location('consumer',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.consume_check_value(sys.argv[2],sys.argv[3],json.loads(sys.argv[4]),sys.argv[5]))",
          consumer,
          prepaid_check_output,
          prepaid_check_output,
          Jason.encode!(prepaid_citations),
          materialized_audit_package
        ],
        stderr_to_stdout: true
      )

    assert prepaid_consumer_status == 0, prepaid_consumer_output
    assert String.trim(prepaid_consumer_output) == "shape2build-k4q9z"

    {:ok, copied_config} =
      Intent.read_config(Path.join(fixture, ".kogen/config.yaml"), config.route)

    assert copied_config.route == config.route
    precompile!(fixture, log_dir)

    # The Shape session runs on the Shaper's own harness, never the
    # Developer-default `config.harness` (they differ on a hybrid route).
    if shaping_harness == "claude" do
      trust = Kogen.LiveClaudeTrust.grant!(fixture)
      on_exit(fn -> Kogen.LiveClaudeTrust.revoke!(trust) end)
    end

    request = "shape2build-#{System.unique_integer([:positive])}"
    brief_path = Path.join(log_dir, "brief.md")
    answers_path = Path.join(log_dir, "answers.md")
    File.write!(brief_path, shaping_brief_content)
    File.write!(answers_path, shaping_answers())

    shaped =
      shape_through_engine!(fixture, log_dir, brief_path, answers_path, request, config.route)

    minted_uuid = shaped.session
    assert minted_uuid =~ @uuid_v7, "the engine session must be the minted UUIDv7 Intent ID"

    draft_dir = Path.join(fixture, ".kogen/intents/drafts/#{@slug}")
    approved_dir = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    approved_intent_path = Path.join(approved_dir, "intent.yaml")

    refute File.dir?(draft_dir), "the Draft directory must be gone after real approval"
    assert File.exists?(approved_intent_path), "the real Approved intent.yaml must exist"

    # Build must consume the package the engine approved, not merely a
    # Shaping run that stopped on an environment failure.
    assert File.regular?(Path.join(approved_dir, "approval.md")),
           "the engine approval must write approval.md into the Approved package"

    approved_record = read_yaml!(approved_intent_path)
    approval = approved_record["approval"]
    assert is_map(approval), "the Approved intent.yaml must carry the engine approval map"
    assert approval["source"] == "mix kogen.shape --approve"
    assert approval["presentation"] == shaped.presentation
    assert approval["request_id"] == "#{request}-approve"
    assert approval["route"] == config.route
    assert approval["authority"] == "interface-attested"
    assert approved_record["id"] == minted_uuid

    assert is_map(approved_record["shaping"])
    assert approved_record["shaping"]["route"] == config.route
    assert approved_record["shaping"]["harness"] == shaping_harness
    assert approved_record["shaping"]["model"] == config.shaping.model
    assert approved_record["shaping"]["effort"] == config.shaping.effort
    assert approved_record["shaping"]["started"]

    # Shape and Build ran in the fixture with its config and login scope.
    shaper_ids = shaped.provider_session_ids
    assert shaper_ids != [], "expected the engine events to record provider session ids"

    Kogen.RootProfileAudit.audit!(
      Path.join(log_dir, "shape-root-profile-audit"),
      Map.new(
        shaper_ids,
        &{&1, %{model: config.shaping.model, effort: config.shaping.effort, role: "shaping"}}
      ),
      Kogen.RootProfileAudit.sessions_root(fixture, :shaping, config.route)
    )

    assert_auditor_receipts!(
      fixture,
      config,
      shaper_ids,
      Path.join(log_dir, "auditor-profile-audit")
    )

    # Retain the shaped contract even when a schema assertion fails before Build.
    File.cp_r!(approved_dir, Path.join(log_dir, "approved-package"))
    approved_intent_content = File.read!(approved_intent_path)
    approved_scenarios_content = File.read!(Path.join(approved_dir, "scenarios.yaml"))
    {:ok, approved_risks} = YamlElixir.read_from_file(Path.join(approved_dir, "risks.yaml"))

    assert approved_intent_content =~ minted_uuid,
           "the real minted identity (#{minted_uuid}) must be preserved into the Approved intent.yaml"

    # The Shaping Controller may describe the outcome, but the exact remediation value is
    # deliberately available only from the failing Make target's own output,
    # which the Build controller later carries into its resume prompt. If it
    # leaks into the shaped package, this would no longer demonstrate a
    # controller-driven correction.
    refute approved_intent_content =~ "shape2build-k4q9z"
    refute approved_scenarios_content =~ "shape2build-k4q9z"

    assert [%{"scenario_ids" => [scenario_id], "ownership" => [ownership]}] = approved_risks
    assert is_binary(scenario_id) and scenario_id != ""
    assert ownership["paths"] =~ "dummy.txt"
    assert ownership["owner_after_creation"] != ownership["owner_during_operation"]
    assert ownership["owner_after_creation"] =~ ~r/fixture|seed/i
    assert ownership["owner_during_operation"] =~ ~r/human|user/i

    # The provider-created package must satisfy the exact local contract and
    # target plan before the paid Build route is allowed to start.
    assert {:ok, contract} = Contract.load(approved_dir, project_root)

    assert {:ok, intent} =
             Intent.read(@slug, Path.join(fixture, ".kogen/intents/approved"))

    assert {:ok, catalog} = VerificationPlan.load(fixture)

    assert {:ok, _plan} =
             VerificationPlan.build(
               contract.scenarios,
               intent.may_change_guarded_paths,
               catalog,
               fixture
             )

    # Real public Build, against the exact package the real Shaping Controller wrote
    # and the real scripted approval moved -- not a hand-written stand-in.
    raw_stream_dir = Path.join(log_dir, "build-raw-streams")

    {build_out, build_exit} =
      System.cmd("mix", ["kogen.build", "--route", config.route, @slug],
        cd: fixture,
        env: [
          # A BEAM crash (for example `erl_child_setup closed`) leaves its dump
          # in the retained log directory, not the deletable fixture.
          {"ERL_CRASH_DUMP", Path.join(log_dir, "erl_crash-build.dump")},
          {"KOGEN_RAW_LOG_DIR", raw_stream_dir},
          {"MIX_BUILD_PATH", Path.join(fixture, "_build")},
          {"KOGEN_JEV_TRANSPORT", nil},
          {"KOGEN_JEV_SECURITY", nil},
          # Only the nested Build's roles run the fixture's SessionStart
          # probe; the unconfined Shape session above skipped it.
          {"KOGEN_BOUNDARY_PROBE_OUTSIDE", Kogen.BoundaryProbeFixture.outside(fixture)}
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "build-console.log"), build_out)

    history_path = Path.join(fixture, ".kogen/runtime/verification-history.jsonl")

    if File.exists?(history_path) do
      File.cp!(history_path, Path.join(log_dir, "verification-history.jsonl"))
    end

    complete_dir = Path.join(fixture, ".kogen/intents/complete/#{@slug}")
    evidence_path = Path.join(complete_dir, "evidence.md")

    if File.exists?(evidence_path) do
      File.cp!(evidence_path, Path.join(log_dir, "evidence.md"))
    end

    Kogen.LiveTrackingRetention.preserve!(fixture, complete_dir, log_dir)

    {git_log, _} =
      System.cmd("git", ["log", "--format=%H%n%B", "-3"], cd: fixture, stderr_to_stdout: true)

    File.write!(Path.join(log_dir, "git-log.txt"), git_log)

    assert build_exit == 0, """
    real mix kogen.build did not succeed (exit #{build_exit}); this is a real failure, not swallowed.
    Console:
    #{build_out}
    Preserved evidence under: #{log_dir}
    """

    assert File.dir?(complete_dir)
    refute File.dir?(Path.join(fixture, ".kogen/intents/approved/#{@slug}"))

    evidence = File.read!(evidence_path)
    [_, resumptions_text] = Regex.run(~r/^- Outer resumptions used: (\d+)$/m, evidence)
    resumptions = String.to_integer(resumptions_text)
    assert resumptions <= config.outer_resumptions

    developer_session_id =
      Regex.run(~r/Developer session id: `([^`]+)`/, evidence) |> List.last()

    reviewer_session_id =
      Regex.run(~r/Reviewer session id: `([^`]+)`/, evidence) |> List.last()

    assert developer_session_id, "expected a Developer session id in evidence.md"
    assert reviewer_session_id, "expected a Reviewer session id in evidence.md"

    tracking = read_tracking!(fixture, complete_dir)
    developer_root = build_sessions_root!(tracking, copied_config, :developer)
    reviewer_root = build_sessions_root!(tracking, copied_config, :reviewer)

    File.write!(
      Path.join(log_dir, "build-profile-store-selection.json"),
      Jason.encode!(
        %{
          "route" => copied_config.route,
          "developer" => profile_store_record(developer_root),
          "reviewer" => profile_store_record(reviewer_root)
        },
        pretty: true
      ) <> "\n"
    )

    # Bind the exact native IDs to the controller's launch stores, checked
    # against the selected role profiles. Claude Build transcripts live in
    # its retained harness home rather than the scope's Shape transcript store.
    Kogen.RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/developer"),
      %{developer_session_id => Map.put(config.developer, :role, "developer")},
      developer_root
    )

    Kogen.RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/reviewer"),
      %{reviewer_session_id => Map.put(config.reviewer, :role, "reviewer")},
      reviewer_root
    )

    assert File.exists?(history_path),
           "the Verification Record history must exist -- the real controller must have run verification itself"

    records =
      history_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    same_session = Enum.filter(records, &(&1["session_id"] == developer_session_id))

    assert Enum.any?(same_session, &(&1["status"] == "failed")),
           "expected an actual failed Check record for session #{developer_session_id}; " <>
             "records: #{inspect(records)}"

    assert Enum.any?(same_session, &(&1["status"] == "passed")),
           "expected an actual passed Check record for session #{developer_session_id}; " <>
             "records: #{inspect(records)}"

    first_failed_index = Enum.find_index(same_session, &(&1["status"] == "failed"))
    first_passed_index = Enum.find_index(same_session, &(&1["status"] == "passed"))

    assert first_failed_index < first_passed_index,
           "the failed record must precede the passed record within the same session"

    # Every controller verification cycle follows exactly one Developer turn
    # of the same session: the first turn of each outer attempt and every
    # controller resume after a failed cycle. So the Developer session has
    # one completed native capture per recorded cycle.
    developer_turns =
      tracking["attempts"]
      |> Enum.flat_map(&get_in(&1, ["verification", "cycles"]))
      |> length()

    assert developer_turns >= 2,
           "the fixture's failing check must force at least one controller resume of the Developer"

    # The Reviewer's session is resumed once for each recorded evidence
    # addendum after its Review turn.
    reviewer_turns =
      1 + Enum.count(tracking["attempts"], &is_map(&1["evidence_addendum"]))

    native_summary =
      Kogen.LiveNativeReceiptAudit.audit!(
        raw_stream_dir,
        %{
          developer_session_id => developer_turns,
          reviewer_session_id => reviewer_turns
        },
        [reviewer_session_id],
        tracking["attempts"]
      )

    File.write!(
      Path.join(log_dir, "native-receipt-summary.json"),
      Jason.encode!(native_summary) <> "\n"
    )

    assert_runtime_version!(fixture, config, raw_stream_dir, developer_session_id, :developer)
    assert_runtime_version!(fixture, config, raw_stream_dir, reviewer_session_id, :reviewer)

    # The frozen route keeps `config.harness` (the Build's dominant,
    # Developer-default harness) and every role's model/effort, plus the
    # dominant harness's native helpers -- only that harness's `expert`
    # helper when the route's Expert role is actually assigned there.
    expected_helpers =
      %{
        "scout" => %{
          "model" => config.helpers.scout.model,
          "effort" => config.helpers.scout.effort
        },
        "worker" => %{
          "model" => config.helpers.worker.model,
          "effort" => config.helpers.worker.effort
        }
      }
      |> maybe_put_expert_helper(config)

    assert tracking["route"] == %{
             "name" => config.route,
             "harness" => config.harness,
             "shaping" => %{"model" => config.shaping.model, "effort" => config.shaping.effort},
             "developer" => %{
               "model" => config.developer.model,
               "effort" => config.developer.effort
             },
             "reviewer" => %{
               "model" => config.reviewer.model,
               "effort" => config.reviewer.effort
             },
             "helpers" => expected_helpers
           }

    [summary_path] = Path.wildcard(Path.join(complete_dir, "build-summary*.json"))
    summary = summary_path |> File.read!() |> Jason.decode!()
    assert summary["route"] == %{"name" => config.route, "harness" => config.harness}

    assert evidence =~
             "- Route: `#{config.route}` (harness `#{config.harness}`)"

    [initial_attempt | _] = tracking["attempts"]

    assert initial_attempt["developer_session_id"] == developer_session_id
    assert is_map(initial_attempt["handoff"]), "initial attempt must contain the first handoff"
    assert_developer_invocation!(initial_attempt, developer_session_id)

    # The failing Check's own output, which the controller's handoff carries to
    # the resumed Developer, names the exact content it must write.
    assert Enum.any?(
             initial_attempt["receipts"] ++ failed_cycle_receipts(initial_attempt),
             fn r ->
               is_binary(r["output"]) and
                 r["output"] =~ "Required exact content: shape2build-k4q9z"
             end
           ),
           "the failed Check's retained receipt must carry the Required exact content output"

    check_receipt =
      Enum.find(initial_attempt["receipts"] ++ failed_cycle_receipts(initial_attempt), fn r ->
        is_binary(r["output"]) and r["output"] =~ "Required exact content:"
      end)

    # Feed the real failed Check output to the same offline value consumer;
    # its cited source bytes are materialized beside the run for audit.
    evidence_package = Path.join(log_dir, "value-evidence-package")
    File.mkdir_p!(Path.join(evidence_package, "evidence"))
    File.cp!(Path.join(fixture, "Makefile"), Path.join(evidence_package, "Makefile"))
    File.cp!(brief_path, Path.join(evidence_package, "evidence/brief.md"))
    makefile_lines = File.read!(Path.join(fixture, "Makefile")) |> String.split("\n")
    brief_line = File.read!(brief_path) |> String.split("\n") |> hd()

    citations = [
      %{path: "evidence/brief.md", line: 1, excerpt: brief_line},
      %{path: "Makefile", line: 2, excerpt: Enum.at(makefile_lines, 1)}
    ]

    consumer = Path.join(project_root, "test/support/shaping_evaluation/value_evidence.py")

    {consumer_output, consumer_status} =
      System.cmd(
        "python3",
        [
          "-B",
          "-c",
          "import importlib.util,sys,json; s=importlib.util.spec_from_file_location('consumer',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.consume_check_value(sys.argv[2],sys.argv[2],json.loads(sys.argv[3]),sys.argv[4]))",
          consumer,
          check_receipt["output"],
          Jason.encode!(citations),
          evidence_package
        ],
        stderr_to_stdout: true
      )

    assert consumer_status == 0, consumer_output
    assert String.trim(consumer_output) == "shape2build-k4q9z"

    assert_controller_handoff!(initial_attempt, contract)
    assert_jev_no_objection!(initial_attempt)

    initial_check_finished_at =
      initial_attempt["receipts"]
      |> List.last()
      |> Map.fetch!("finished_at")

    {:ok, initial_check_finished, 0} = DateTime.from_iso8601(initial_check_finished_at)

    before_initial_handoff =
      Enum.filter(same_session, fn record ->
        {:ok, finished, 0} = DateTime.from_iso8601(record["finished_at"])
        DateTime.compare(finished, initial_check_finished) != :gt
      end)

    assert Enum.map(before_initial_handoff, & &1["status"]) |> Enum.take(-2) ==
             ["failed", "passed"],
           "outer driver must observe controller-owned failed-then-passed Verification Record history before the initial handoff"

    initial_cycle_statuses = Enum.map(initial_attempt["verification"]["cycles"], & &1["status"])

    assert "failed" in initial_cycle_statuses and List.last(initial_cycle_statuses) == "passed",
           "the initial attempt's own controller verification cycles must show failed-then-passed for the same Developer session"

    assert_candidate_build!(
      fixture,
      config,
      tracking,
      initial_attempt,
      developer_session_id,
      reviewer_session_id,
      raw_stream_dir
    )

    subject = git!(fixture, ["log", "-1", "--format=%s"])
    assert subject == "Shape to build probe"

    {trailer_out, 0} =
      System.cmd("sh", ["-c", "git log -1 --format=%B | git interpret-trailers --parse"],
        cd: fixture
      )

    assert trailer_out =~ "Kogen-Intent-ID: #{minted_uuid}"
    assert trailer_out =~ "Kogen-Intent: #{@slug}"

    assert git!(fixture, ["log", "-1", "--format=%B"]) ==
             "Shape to build probe\n\nKogen-Intent-ID: #{minted_uuid}\nKogen-Intent: #{@slug}"

    File.rm_rf!(fixture)
    File.rmdir!(fixture_parent)
    assert :ok = Kogen.LiveReworkAudit.audit_retained!(log_dir)
  end

  # Each role's actual runtime version comes from its own assigned harness's
  # native receipt, resolved via `Intent.role_harness/2` -- never a hardcoded
  # per-test harness guess, which would silently stop proving anything once a
  # route reassigns that role to the other harness. Claude's runtime version
  # is carried in the raw stream's own `system/init` event; Codex exec JSONL
  # does not carry `cli_version`, so it is read from the native rollout
  # session store instead (this must run before the fixture is removed).
  # The Shaping auditor is a separate identity from the Shaper: each launched
  # auditor record names the route's frozen auditor profile, and that exact
  # native session proves the model, effort and pinned runtime it ran on.
  defp assert_auditor_receipts!(fixture, config, shaper_ids, evidence_dir) do
    assert {:ok, auditor} = Intent.auditor_config(config)

    if config.route == "optimum",
      do: assert(auditor == %{harness: "claude", model: "claude-opus-5-5", effort: "high"})

    records =
      fixture
      |> Path.join(".kogen/runtime/shaping-audits/#{@slug}/auditor/*.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
      |> Enum.filter(&(&1["launched"] == true and is_binary(&1["session_id"])))

    assert records != [], "expected at least one launched Shaping auditor record"

    File.mkdir_p!(evidence_dir)
    File.write!(Path.join(evidence_dir, "auditor-records.json"), Jason.encode!(records) <> "\n")

    for record <- records do
      assert Map.take(record, ["route", "harness", "model", "effort"]) == %{
               "route" => config.route,
               "harness" => auditor.harness,
               "model" => auditor.model,
               "effort" => auditor.effort
             }
    end

    ids = records |> Enum.map(& &1["session_id"]) |> Enum.uniq()
    refute Enum.any?(ids, &(&1 in shaper_ids)), "the auditor must be a separate session"
    root = Kogen.RootProfileAudit.harness_sessions_root(fixture, auditor.harness)

    Kogen.RootProfileAudit.audit!(
      evidence_dir,
      Map.new(ids, &{&1, %{model: auditor.model, effort: auditor.effort, role: "auditor"}}),
      root
    )

    expected =
      if auditor.harness == "claude",
        do: Kogen.ClaudeCode.pinned_version(),
        else: Kogen.ManagedRuntimeReady.codex_version()

    for {id, versions} <- Kogen.RootProfileAudit.runtime_versions!(root, ids) do
      assert expected in versions,
             "auditor session #{id} must identify runtime #{expected}, got #{inspect(versions)}"
    end
  end

  defp assert_runtime_version!(fixture, config, raw_dir, session_id, role) do
    case Kogen.Intent.role_harness(config, role) do
      "claude" ->
        expected = Kogen.ClaudeCode.pinned_version()

        versions =
          raw_dir
          |> Path.join("raw-stream-*.jsonl")
          |> Path.wildcard()
          |> Enum.flat_map(&claude_runtime_versions(&1, session_id))

        assert expected in versions,
               "claude #{role} receipt #{session_id} must identify #{expected}, got #{inspect(versions)}"

      "codex" ->
        sessions_root = Kogen.RootProfileAudit.sessions_root(fixture, role, config.route)
        versions = Kogen.RootProfileAudit.codex_cli_versions!(sessions_root, [session_id])

        assert versions == %{session_id => Kogen.ManagedRuntimeReady.codex_version()},
               "codex #{role} rollout #{session_id} must identify #{Kogen.ManagedRuntimeReady.codex_version()}, got #{inspect(versions)}"
    end
  end

  # Claude Code's stream `system/init` names its runtime. Codex exec JSONL
  # carries no `cli_version`; its version comes from the bound native rollout
  # `session_meta` through `RootProfileAudit.codex_cli_versions!/2` above.
  defp claude_runtime_versions(path, session_id) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok,
         %{
           "type" => "system",
           "subtype" => "init",
           "session_id" => ^session_id,
           "claude_code_version" => version
         }} ->
          [version]

        _ ->
          []
      end
    end)
  end

  defp maybe_put_expert_helper(helpers, %{helpers: %{expert: expert}}) do
    Map.put(helpers, "expert", %{"model" => expert.model, "effort" => expert.effort})
  end

  defp maybe_put_expert_helper(helpers, _config), do: helpers

  defp shaping_brief do
    """
    For this bounded, single fixture probe: shape exactly one tiny Intent with slug #{@slug}. Title: Shape to build probe. may_change_guarded_paths: only dummy.txt. Exactly one scenario, verified_by check, whose then clause requires dummy.txt to exist at the repo root containing a specific exact value that this scenario text must NOT state -- the future Developer must learn the exact required value only from the failed check output that the Build controller's own verification reports back in its resume message, then fix it, then stop again; do not let the Developer discover it before that first controller-reported failed verification. Name the scenario id controller-verification-recovery. The scenario proof map must use test/kogen/shape_task_test.exs as its offline selector; Makefile, lib paths, and arbitrary existing files are not valid proof selectors. Set proof.affected_paths to [dummy.txt] so every affected path is guarded and repairable by the Build. The outer test driver observes controller discovery and the failed-then-passed verification history; neither behavior is a Draft obligation. Add risks.yaml with one risk linked to that scenario. Its required ownership entry must state that dummy.txt is owned by the fixture seed immediately after creation and by the human user during operation; use nonblank YAML string values for every ownership field, including the scalar paths: dummy.txt (not a list), and make owner_after_creation and owner_during_operation different. Keep the scenario's then clause and evidence limited to what a Reviewer can judge from the Candidate and the Review packet: dummy.txt exists containing the exact value and the packet's controller Check receipt passed. Do NOT make the Reviewer's acceptance depend on reading .kogen/runtime/verification-history.jsonl or on any failed-then-passed record sequence; the outer test driver independently audits the failed-then-passed history, so the Draft must say that audit is outside the Reviewer's remit. Ground these claims in evidence the audit can check, without ever quoting the required value: cite evidence/brief.md:1 for the required offline selector and for withholding the value; cite this checkout's Makefile:2 check rule as evidence that a failed check prints the required value; and state in proof.paid_reason that the offline selector does not observe dummy.txt, so verified_by check is its only oracle.
    """
  end

  defp shaping_answers do
    """
    Proceed with the bounded probe exactly as briefed. Every question is settled by the brief: choose the most conservative option that keeps dummy.txt as the only guarded path, do not add scenarios, and do not ask further questions. Present the finished package.
    """
  end

  # The external driver: never a managed role and no Shaping environment.
  defp external_driver_env(fixture, log_dir) do
    shaping =
      for {key, _} <- System.get_env(), String.starts_with?(key, "KOGEN_SHAPING_"), do: {key, nil}

    [
      {"KOGEN_ROLE", nil},
      {"KOGEN_JEV_TRANSPORT", nil},
      {"KOGEN_JEV_SECURITY", nil},
      {"MIX_BUILD_PATH", Path.join(fixture, "_build")},
      {"ERL_CRASH_DUMP", Path.join(log_dir, "erl_crash-shape.dump")}
      | shaping
    ]
  end

  defp engine!(fixture, log_dir, args) do
    {out, exit_code} =
      System.cmd("mix", ["kogen.shape" | args],
        cd: fixture,
        env: external_driver_env(fixture, log_dir),
        stderr_to_stdout: false
      )

    File.write!(
      Path.join(log_dir, "shape-engine-commands.log"),
      "$ mix kogen.shape #{Enum.join(args, " ")}\n(exit #{exit_code})\n#{out}\n",
      [:append]
    )

    line = out |> String.split("\n", trim: true) |> List.last()

    payload =
      case line && Jason.decode(line) do
        {:ok, %{} = map} -> map
        _ -> flunk("engine stdout is not one JSON object (exit #{exit_code}): #{inspect(out)}")
      end

    {exit_code, payload}
  end

  defp poll_engine!(fixture, log_dir, session, deadline) do
    {_code, status} = engine!(fixture, log_dir, [session])
    state = status["state"]

    cond do
      state in ["awaiting_answers", "ready"] ->
        status

      state in ["blocked", "interrupted", "cancelled", "failed"] ->
        flunk("engine session stopped in #{state}, not a shaped package: #{inspect(status)}")

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Shaping did not settle within 20 minutes; last status: #{inspect(status)}")

      true ->
        Process.sleep(@poll_ms)
        poll_engine!(fixture, log_dir, session, deadline)
    end
  end

  # start -> poll -> (answer -> poll)* -> approve, all through the public
  # engine commands. Returns the approved session's evidence.
  defp shape_through_engine!(fixture, log_dir, brief, answers, request, route) do
    deadline = System.monotonic_time(:millisecond) + @shaping_bound_ms

    {_code, started} =
      engine!(fixture, log_dir, [
        "--brief",
        brief,
        "--route",
        route,
        "--request-id",
        "#{request}-start"
      ])

    session = started["session"]
    assert is_binary(session), "engine start must return a session id: #{inspect(started)}"

    status = poll_engine!(fixture, log_dir, session, deadline)
    status = answer_until_ready!(fixture, log_dir, session, answers, request, status, deadline, 1)

    presentation = (status["presented"] || %{})["id"]
    assert is_binary(presentation), "a ready session must present a package: #{inspect(status)}"

    {code, approved} =
      engine!(fixture, log_dir, [
        session,
        "--approve",
        presentation,
        "--request-id",
        "#{request}-approve"
      ])

    refute approved["error"], "engine refused approval (exit #{code}): #{inspect(approved)}"
    assert code == 0

    events_path = Path.join(fixture, ".kogen/runtime/shaping/#{session}/events.jsonl")

    events =
      if File.exists?(events_path),
        do:
          events_path
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1),
        else: []

    %{
      session: session,
      presentation: presentation,
      provider_session_ids:
        events |> Enum.map(& &1["provider_session_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  defp answer_until_ready!(fixture, log_dir, session, answers, request, status, deadline, round) do
    case status["state"] do
      "ready" ->
        status

      "awaiting_answers" when round <= @max_answer_rounds ->
        {code, sent} =
          engine!(fixture, log_dir, [
            session,
            "--brief",
            answers,
            "--request-id",
            "#{request}-answer-#{round}"
          ])

        refute sent["error"],
               "engine refused the scripted answer (exit #{code}): #{inspect(sent)}"

        next = poll_engine!(fixture, log_dir, session, deadline)

        answer_until_ready!(
          fixture,
          log_dir,
          session,
          answers,
          request,
          next,
          deadline,
          round + 1
        )

      state ->
        flunk("Shaping never reached ready (state #{state} after #{round - 1} answers)")
    end
  end

  defp owned_log_dir(project_root) do
    base =
      System.get_env("KOGEN_LIVE_LOG_DIR") ||
        Path.join(project_root, ".kogen/runtime/live-evidence")

    dir =
      Path.join(
        base,
        "shape-to-build-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp transcript_cwds(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"cwd" => cwd}} when is_binary(cwd) -> [cwd]
        _ -> []
      end
    end)
  end

  # A failed test leaves its fixture behind. Copy the runtime state (phase logs,
  # Developer prompts) and any erl_crash.dump into the retained log dir, then
  # drop the bulky checkout. Success already removed the fixture.
  defp retain_failed_fixture!(fixture, log_dir) do
    if File.dir?(fixture) do
      retained = Path.join(log_dir, "retained-fixture")
      File.mkdir_p!(retained)
      File.cp!(Path.join(fixture, ".kogen/config.yaml"), Path.join(retained, "config.yaml"))

      runtime = Path.join(fixture, ".kogen/runtime")
      if File.dir?(runtime), do: File.cp_r!(runtime, Path.join(retained, "runtime"))

      audits = Path.join(fixture, ".kogen/runtime/shaping-audits/#{@slug}")
      if File.dir?(audits), do: File.cp_r!(audits, Path.join(retained, "shaping-audits"))

      retain_packages!(fixture, retained)

      statuses = retained_statuses(Path.join(log_dir, "shape-engine-commands.log"))

      File.write!(
        Path.join(retained, "shape-status-responses.json"),
        Jason.encode!(statuses, pretty: true) <> "\n"
      )

      fixture
      |> Path.join("**/erl_crash.dump")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/deps/"))
      |> Enum.with_index()
      |> Enum.each(fn {dump, i} -> File.cp!(dump, Path.join(retained, "erl_crash-#{i}.dump")) end)

      File.rm_rf!(fixture)

      IO.puts(
        "\nLive shape-to-build FAILED; fixture evidence retained in #{retained} " <>
          "(logs in #{log_dir})"
      )
    end
  end

  defp retain_packages!(fixture, retained) do
    for location <- ~w(drafts approved) do
      package = Path.join(fixture, ".kogen/intents/#{location}/#{@slug}")
      if File.dir?(package), do: File.cp_r!(package, Path.join(retained, "#{location}/#{@slug}"))
    end
  end

  defp retained_statuses(path) do
    case File.read(path) do
      {:ok, command_log} ->
        command_log |> String.split("\n", trim: true) |> Enum.flat_map(&status_line/1)

      {:error, _reason} ->
        []
    end
  end

  defp status_line(line) do
    case Jason.decode(line) do
      {:ok, %{"state" => _state} = status} -> [status]
      _ -> []
    end
  end

  # The nested Build ran in its own Candidate worktree with its own harness
  # home, logged in through the scope reference, inside the write boundary,
  # and published: the Candidate worktree and branch are gone. The
  # Claude-specific transcript-location assertions only apply to whichever
  # roles the resolved route actually assigns to Claude.
  defp assert_candidate_build!(
         fixture,
         config,
         tracking,
         attempt,
         developer,
         reviewer,
         raw_stream_dir
       ) do
    candidate = tracking["candidate"]
    worktree = candidate["worktree_path"]
    assert candidate["disposition"] == "published"
    assert candidate["control_root"] == Workspace.canonical(fixture)

    assert System.get_env("KOGEN_WORKSPACES_ROOT") =~ " ",
           "the live workspaces root must contain a space"

    refute File.exists?(worktree), "the published Candidate worktree must be removed"

    refute match?(
             {_, 0},
             System.cmd("git", ["show-ref", "--verify", "refs/heads/" <> candidate["branch"]],
               cd: fixture,
               stderr_to_stdout: true
             )
           ),
           "the published Candidate branch must be removed"

    for receipt <- attempt["receipts"],
        do: assert(receipt["candidate_id"] == attempt["candidate_id"])

    claude_sessions =
      for {role, session} <- [developer: developer, reviewer: reviewer],
          Intent.role_harness(config, role) == "claude",
          do: session

    if claude_sessions != [] do
      # The Claude binding names the scope resolved from control; transcripts
      # of the Build's Claude roles live in the per-Build config dir, never
      # in the scope.
      {:ok, scope} = Kogen.ClaudeCode.effective_scope(fixture)

      assert [%{"scope_path" => scope_path}] =
               Enum.filter(candidate["credential_bindings"], &(&1["harness"] == "claude"))

      assert scope_path == scope.path
      projects = Path.join([candidate["harness_home"], "claude", "projects"])

      for session <- claude_sessions do
        assert [transcript] = Path.wildcard(Path.join(projects, "*/#{session}.jsonl")),
               "session #{session} must be recorded under the Build's harness home"

        assert Path.wildcard(Path.join([scope.path, "projects", "*", "#{session}.jsonl"])) == [],
               "session #{session} must not be recorded under the login scope"

        cwds = transcript_cwds(transcript)
        assert cwds != [], "the transcript of #{session} records no cwd"

        # Claude Code records the Bash tool's current directory, which a role
        # may move within its Candidate; the session starts in the Candidate
        # and never leaves it.
        assert hd(cwds) == worktree, "session #{session} did not start in the Candidate"

        assert Enum.all?(cwds, &(&1 == worktree or String.starts_with?(&1, worktree <> "/"))),
               "session #{session} ran outside the Candidate: #{inspect(Enum.uniq(cwds))}"
      end

      if Intent.role_harness(config, :developer) == "claude" do
        # The Developer's first turn and its controller resume share one
        # session.
        assert developer
               |> then(&Path.wildcard(Path.join(projects, "*/#{&1}.jsonl")))
               |> length() == 1
      end

      if Intent.role_harness(config, :shaping) == "claude" do
        # The interactive Shape session before it used the scope's own
        # config dir.
        assert Path.wildcard(Path.join([scope.path, "projects", "*", "*.jsonl"]))
               |> Enum.any?(&(Workspace.canonical(fixture) in transcript_cwds(&1))),
               "the Shape transcript must be recorded under the login scope"
      end
    end

    # Every role process tree ran inside the Build's boundary.
    assert tracking["boundary"]["mode"] == "applied"
    lines = Kogen.BoundaryProbeFixture.lines(raw_stream_dir)
    developer_lines = Enum.filter(lines, &(&1["session_id"] == developer))
    reviewer_lines = Enum.filter(lines, &(&1["session_id"] == reviewer))

    assert length(developer_lines) >= 2,
           "expected the fresh and the resumed Developer session to run the probe"

    assert reviewer_lines != [], "expected the Reviewer session to run the probe"

    Enum.each(
      developer_lines ++ reviewer_lines,
      &Kogen.BoundaryProbeFixture.assert_bounded!(&1, worktree)
    )

    Kogen.BoundaryProbeFixture.assert_nothing_escaped!(fixture)
  end

  defp failed_cycle_receipts(attempt) do
    attempt
    |> get_in(["verification", "cycles"])
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1["receipts"]))
    |> Enum.filter(&(&1["status"] == "failed"))
  end

  defp assert_developer_invocation!(attempt, session_id) do
    invocation = attempt["developer_invocation"]
    notes = attempt["developer_notes"]

    refute Map.has_key?(invocation, "schema"),
           "Developer invocation must carry no handoff schema"

    assert invocation["outcome"] == "settled"
    assert invocation["session_id"] == session_id
    assert invocation["message"] == notes["text"]
    assert invocation["message_sha256"] == notes["sha256"]

    assert invocation["message_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, invocation["message"]), case: :lower)
  end

  defp assert_controller_handoff!(attempt, contract) do
    handoff = attempt["handoff"]

    assert handoff["format"] == "kogen-controller-handoff-report"
    assert handoff["built_by"] == "controller"
    assert handoff["attempt_token"] == attempt["attempt_token"]
    assert handoff["candidate_id"] == attempt["candidate_id"]

    assert Enum.map(handoff["scenarios"], & &1["id"]) ==
             Enum.map(contract.scenarios, & &1["id"])
  end

  defp assert_jev_no_objection!(attempt) do
    jev = attempt["jev"]

    assert jev["outcome"] == "answered"
    assert jev["model"] == "jev-1.13.0"

    assert jev["request"]["sha256"] ==
             Base.encode16(:crypto.hash(:sha256, jev["request"]["body"]), case: :lower)

    refute Enum.any?(jev["answers"], fn {id, answer} ->
             String.starts_with?(id, "objection:") and
               answer["choice"] == "objection" and
               answer["confidence"] >= 0.85
           end),
           "no scenario/risk/finding objection should have stopped this settled attempt"

    assert attempt["outcome"] != "cannot_comply"
  end

  defp setup_fixture(project_root, fixture, brief) do
    {_out, 0} =
      System.cmd(
        "rsync",
        [
          "-a",
          "--exclude=_build",
          "--exclude=deps",
          "--exclude=.git",
          "--exclude=.kogen/runtime",
          "--exclude=.kogen/build.lock",
          "--exclude=.kogen/intents",
          project_root <> "/",
          fixture <> "/"
        ]
      )

    Kogen.DependencyFixture.copy!(Path.join(project_root, "deps"), Path.join(fixture, "deps"))

    {:ok, catalog} = VerificationPlan.load(project_root)

    other_targets =
      catalog.entries
      |> Enum.reject(&(&1["name"] == "check"))
      |> VerificationPlan.render_target_declarations()

    File.write!(Path.join(fixture, "Makefile"), @check_rule <> other_targets)
    File.mkdir_p!(Path.join(fixture, "evidence"))
    File.write!(Path.join(fixture, "evidence/brief.md"), brief)
    # Both probes: the route may assign Claude and Codex roles (a Codex
    # Reviewer runs only the `.codex` hook, a Claude Developer only `.claude`).
    Kogen.BoundaryProbeFixture.install_codex!(fixture)
    Kogen.BoundaryProbeFixture.install_claude!(fixture)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: fixture, env: env)
  end

  defp precompile!(fixture, log_dir) do
    {out, exit_code} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: fixture,
        env: [{"MIX_BUILD_PATH", Path.join(fixture, "_build")}],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "fixture-precompile.log"), out)

    assert exit_code == 0, "fixture pre-compile failed (exit #{exit_code}):\n#{out}"
  end

  defp build_sessions_root!(tracking, config, role) do
    assignment = tracking["role_assignment"][Atom.to_string(role)]
    harness = Intent.role_harness(config, role)
    profile = Map.fetch!(config, role)
    assert tracking["route"]["name"] == config.route
    assert assignment["harness"] == harness
    assert assignment["model"] == profile.model
    assert assignment["effort"] == profile.effort

    case harness do
      "claude" ->
        home = tracking["candidate"]["harness_home"]
        assert is_binary(home)
        {:claude, Path.join([home, "claude", "projects"])}

      "codex" ->
        binding =
          Enum.find(tracking["candidate"]["credential_bindings"], &(&1["harness"] == "codex"))

        assert is_map(binding) and is_binary(binding["scope_path"])
        Path.join(binding["scope_path"], "sessions")
    end
  end

  defp profile_store_record({:claude, root}), do: %{harness: "claude", root: root}
  defp profile_store_record(root), do: %{harness: "codex", root: root}

  defp read_tracking!(fixture, _complete_dir) do
    paths = Path.wildcard(Path.join(fixture, ".kogen/runtime/scenario-tracking/*/record.json"))
    assert [path] = paths, "expected exactly one lifecycle scenario-tracking record"
    path |> File.read!() |> Jason.decode!()
  end

  defp read_yaml!(path) do
    assert File.exists?(path), "expected retained continuation state at #{path}"
    {:ok, yaml} = YamlElixir.read_from_file(path)
    yaml
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
