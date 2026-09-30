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
  the real Shaping Controller (`mix kogen.shape`, driven through a genuine
  pty) drafts an Intent, receives explicit scripted test approval (test
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
  history, cleaned up at the end -- placed under this checkout's own
  `.kogen/runtime/` so it inherits this directory's already-established
  Codex trust. Claude Code keys trust on the fixture's own repository root,
  so under `harness: claude` the test pre-trusts only that fixture through
  the documented `hasTrustDialogAccepted` setting in the selected Kogen scope
  and removes the entry afterwards; Kogen itself never answers the dialog.
  The Shape driver still handles either Codex trust state in code
  (`test/support/shape_to_build_probe.exp`), it just isn't required to prove
  the one-time trust dialog itself here. Raw provider streams
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
  @continuation_marker "continuation-evidence-k4q9z"

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

  test "real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent" do
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

    runtime_root = Path.join(project_root, ".kogen/runtime/live-shape2build")
    File.mkdir_p!(runtime_root)

    fixture =
      Path.join(
        runtime_root,
        "fixture-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(fixture)
    # Success removes the fixture inside the test; a fixture still present here
    # means the test failed, so its evidence is retained beside the live logs.
    on_exit(fn -> retain_failed_fixture!(fixture, log_dir) end)

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    setup_fixture(project_root, fixture)

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

    pty_log =
      Path.join(log_dir, "shape-pty-transcript-#{System.system_time(:second)}.log")

    continuation_state_dir = Path.join(log_dir, "continuation-state")

    {diagnostics, shape_exit} =
      System.cmd(
        "expect",
        [
          "-f",
          Path.join(project_root, "test/support/shape_to_build_probe.exp"),
          fixture,
          pty_log,
          @slug,
          continuation_state_dir,
          @continuation_marker,
          config.route
        ],
        env: [
          {"MIX_BUILD_PATH", Path.join(fixture, "_build")},
          {"ERL_CRASH_DUMP", Path.join(log_dir, "erl_crash-shape.dump")}
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "shape-probe-diagnostics.txt"), diagnostics)

    assert shape_exit == 0, """
    real Shape probe did not complete (exit #{shape_exit}); this is a real failure, not swallowed.
    Diagnostics:
    #{diagnostics}
    Raw pty transcript: #{pty_log}
    """

    draft_dir = Path.join(fixture, ".kogen/intents/drafts/#{@slug}")
    approved_dir = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    approved_intent_path = Path.join(approved_dir, "intent.yaml")

    refute File.dir?(draft_dir), "the Draft directory must be gone after real approval"
    assert File.exists?(approved_intent_path), "the real Approved intent.yaml must exist"

    original_intent =
      continuation_state_dir
      |> Path.join("original-intent.yaml")
      |> read_yaml!()

    continued_intent =
      continuation_state_dir
      |> Path.join("continued-intent.yaml")
      |> read_yaml!()

    pre_approval_dir = Path.join(continuation_state_dir, "pre-approval-package")
    post_approval_dir = Path.join(continuation_state_dir, "post-approval-package")

    assert File.dir?(pre_approval_dir), "pre-approval package snapshot must be retained"
    assert File.dir?(post_approval_dir), "post-approval package snapshot must be retained"

    continuation_read =
      continuation_state_dir
      |> Path.join("continuation-read.md")
      |> File.read!()

    assert continuation_read =~ @continuation_marker,
           "the fresh continuation must read saved draft evidence containing the unique marker"

    assert continued_intent["id"] == original_intent["id"]
    assert continued_intent["slug"] == original_intent["slug"]
    assert continued_intent["shaping"] == original_intent["shaping"]
    assert continued_intent["shaped_against"] == original_intent["shaped_against"]

    assert is_map(original_intent["shaping"])
    assert original_intent["shaping"]["route"] == config.route
    assert original_intent["shaping"]["harness"] == shaping_harness
    assert original_intent["shaping"]["model"] == config.shaping.model
    assert original_intent["shaping"]["effort"] == config.shaping.effort
    assert original_intent["shaping"]["started"]

    assert [continuation] = continued_intent["shaping_continuations"],
           "one continuation visit must be saved before the new conversation approves the draft"

    assert is_map(continuation)
    assert continuation["route"] == config.route
    assert continuation["harness"] == shaping_harness
    assert continuation["model"] == config.shaping.model
    assert continuation["effort"] == config.shaping.effort
    assert continuation["started"]
    assert is_map(continuation["checkout"])
    assert continuation["checkout"]["branch"]
    assert continuation["checkout"]["head"]

    pre_approval_intent = read_yaml!(Path.join(pre_approval_dir, "intent.yaml"))
    post_approval_intent = read_yaml!(Path.join(post_approval_dir, "intent.yaml"))

    for key <- ["id", "slug", "shaped_against", "shaping", "shaping_continuations"] do
      assert post_approval_intent[key] == pre_approval_intent[key],
             "approval changed protected intent field #{key}"
    end

    for file <- ["scenarios.yaml", "risks.yaml"] do
      assert File.read!(Path.join(post_approval_dir, file)) ==
               File.read!(Path.join(pre_approval_dir, file)),
             "approval changed agreed requirements in #{file}"
    end

    # Shape and Build ran in the fixture with its config and login scope.
    shape_receipt =
      Kogen.RootProfileAudit.audit_shape!(
        Path.join(log_dir, "shape-root-profile-audit"),
        fixture,
        %{model: config.shaping.model, effort: config.shaping.effort},
        Kogen.RootProfileAudit.sessions_root(fixture, :shaping, config.route)
      )

    shaper_ids = Enum.map(shape_receipt["sessions"], & &1["id"])

    assert_auditor_receipts!(
      fixture,
      config,
      shaper_ids,
      Path.join(log_dir, "auditor-profile-audit")
    )

    transcript = File.read!(pty_log)

    minted_uuid =
      Regex.run(
        ~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/,
        transcript
      )
      |> List.first()

    assert minted_uuid, "expected a freshly minted UUIDv7 printed in the transcript"

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
      System.cmd("mix", ["kogen.build", @slug],
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

    # Each role is audited in its own assigned harness's native session
    # store, so a hybrid route proves the Reviewer really ran on its own
    # harness, distinct from the Developer's.
    Kogen.RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/developer"),
      %{developer_session_id => Map.put(config.developer, :role, "developer")},
      Kogen.RootProfileAudit.sessions_root(fixture, :developer, config.route)
    )

    Kogen.RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit/reviewer"),
      %{reviewer_session_id => Map.put(config.reviewer, :role, "reviewer")},
      Kogen.RootProfileAudit.sessions_root(fixture, :reviewer, config.route)
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

    tracking = read_tracking!(fixture, complete_dir)

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

      runtime = Path.join(fixture, ".kogen/runtime")
      if File.dir?(runtime), do: File.cp_r!(runtime, Path.join(retained, "runtime"))

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

  defp setup_fixture(project_root, fixture) do
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
