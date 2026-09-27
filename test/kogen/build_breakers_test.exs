defmodule Kogen.BuildBreakersTest do
  use Kogen.IsolatedCase, async: true

  @moduletag timeout: 600_000

  alias Kogen.Build.Breakers
  alias Kogen.CandidateFixture, as: Candidate
  alias Kogen.WorkspaceFixture, as: Workspace

  defp reports(control), do: Breakers.reports(control)

  defp report!(control, build_id, attrs) do
    path = Path.join(control, ".kogen/runtime/scenario-tracking/#{build_id}/failure-report.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.merge(%{"build_id" => build_id}, attrs)))
    Path.expand(path)
  end

  defp report_paths(control), do: Enum.map(reports(control), & &1.path)

  defp latest_report!(control), do: List.last(reports(control)).report

  defp admission_counts(control) do
    tracking =
      control
      |> Path.join(".kogen/runtime/scenario-tracking/*")
      |> Path.wildcard()
      |> Enum.count(&File.dir?/1)

    worktrees =
      control
      |> Candidate.registered_worktrees()
      |> length()

    {tracking, length(Workspace.owner_records(control)), worktrees}
  end

  defp probe_lines(cwd) do
    path = Path.join(cwd, ".kogen/runtime/fake-harness-log")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "argv:"))
    else
      []
    end
  end

  defp claude_opts(claude_root, cwd, logged_out, extra \\ []) do
    [
      route: "claude",
      cwd: cwd,
      harness: Workspace.support("fake_claude"),
      env:
        [
          {"KOGEN_CLAUDE_ROOT", claude_root},
          {"KOGEN_HARNESS_HOME", nil},
          {"FAKE_CLAUDE_LOGGED_OUT", if(logged_out, do: "1", else: "0")}
        ] ++ extra
    ]
  end

  defp provider_tail!(name) do
    path = Path.join([Workspace.project_root(), "test/support/provider_tails", name])
    Jason.decode!(File.read!(path))["output"]
  end

  defp write_tail!(name, json_name) do
    path = Path.join(Workspace.tmp_dir!(name), "tail.jsonl")
    File.write!(path, provider_tail!(json_name))
    path
  end

  defp timestamp(offset) do
    DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.to_iso8601()
  end

  defp clear_files(control) do
    Path.wildcard(Path.join(control, ".kogen/runtime/scenario-tracking/*/environment-clear.json"))
  end

  defp record_paths(control) do
    Path.wildcard(Path.join(control, ".kogen/runtime/scenario-tracking/*/record.json"))
  end

  defp clear_for_slug!(control, slug) do
    record_paths(control)
    |> Enum.filter(fn path ->
      path |> File.read!() |> Jason.decode!() |> get_in(["intent", "slug"]) == slug
    end)
    |> Enum.map(&Path.join(Path.dirname(&1), "environment-clear.json"))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> raise "missing environment clear for #{slug}"
      path -> path |> File.read!() |> Jason.decode!()
    end
  end

  defp prompt_path(report),
    do: Path.join(report["candidate"]["harness_home"], "fake-state/developer-launch-prompt")

  defp prompt!(report), do: File.read!(prompt_path(report))

  defp first_failure_span(text) do
    [_, rest] = String.split(text, "## First failure", parts: 2)

    marker =
      "Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it deterministic; an unchanged Candidate stops the Build.\n"

    [body, _] = String.split(rest, marker, parts: 2)
    "## First failure" <> body <> marker
  end

  test "1. repeated unchanged item failures refuse before admission" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]

    assert {:error, first_message} = Workspace.build!(control, opts)
    assert first_message =~ "category: offline-exhausted"
    assert {:error, second_message} = Workspace.build!(control, opts)
    assert second_message =~ "category: offline-exhausted"
    [first, second] = reports(control)
    assert first.report["signature"]["digest"] == second.report["signature"]["digest"]
    before = {admission_counts(control), Workspace.control_state(control)}

    marker = Workspace.tmp_dir!("item-breaker-marker") |> Path.join("launched")

    sentinel =
      Workspace.fake!(
        Workspace.tmp_dir!("item-breaker-sentinel"),
        "sentinel",
        "#!/bin/sh\ntouch #{marker}\nexit 1\n"
      )

    assert {:error, refusal} =
             Workspace.build!(control, harness: sentinel, env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}])

    expected =
      "Build refused (item breaker): workspace-fixture stopped 2 times with the same failure signature on this Approved package; next action: reshape_details; first failure: check; signature: #{first.report["signature"]["digest"]}; failure reports: #{first.path}, #{second.path}"

    assert refusal == expected
    assert admission_counts(control) == elem(before, 0)
    assert Workspace.control_state(control) == elem(before, 1)
    assert report_paths(control) == [first.path, second.path]
    refute File.exists?(marker)
  end

  test "2. item counts files on disk after deleting a report" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]

    assert {:error, _} = Workspace.build!(control, opts)
    assert {:error, _} = Workspace.build!(control, opts)
    [first, _second] = reports(control)
    File.rm!(first.path)

    assert {:error, admitted_message} = Workspace.build!(control, opts)
    assert admitted_message =~ "category: offline-exhausted"
    refute String.starts_with?(admitted_message, "Build refused")
    [remaining, new_report] = reports(control)
    assert new_report.report["same_signature_count"] == 2

    assert {:error, refusal} = Workspace.build!(control, opts)
    assert refusal =~ "failure reports: #{remaining.path}, #{new_report.path}"
    assert refusal =~ "stopped 2 times with the same failure signature"
  end

  test "3. editing the Approved package changes the item-breaker key" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]

    assert {:error, _} = Workspace.build!(control, opts)
    assert {:error, _} = Workspace.build!(control, opts)
    before = reports(control)
    package = Path.join(control, ".kogen/intents/approved/workspace-fixture/intent.yaml")
    File.write!(package, File.read!(package) <> "# edited\n")

    assert {:error, message} = Workspace.build!(control, opts)
    assert message =~ "category: offline-exhausted"
    refute String.starts_with?(message, "Build refused")
    after_edit = latest_report!(control)
    assert after_edit["approved_package_digest"] != hd(before).report["approved_package_digest"]
    assert after_edit["same_signature_count"] == 1
    assert after_edit["next_action"] == "rebuild"
  end

  test "4. another Intent is never refused by this Intent's reports" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]

    assert {:error, _} = Workspace.build!(control, opts)
    assert {:error, _} = Workspace.build!(control, opts)

    Workspace.write_intent!(control, "second-intent",
      intent_id: "01a0c467-0000-7000-8000-00000000b2e2"
    )

    assert {:error, message} =
             Workspace.build!(control, Keyword.put(opts, :slug, "second-intent"))

    assert message =~ "category: offline-exhausted"
    refute String.starts_with?(message, "Build refused")
    report = latest_report!(control)
    assert report["intent_id"] == "01a0c467-0000-7000-8000-00000000b2e2"
    [first, second] = reports(control) |> Enum.take(2)
    assert report["signature"]["digest"] == first.report["signature"]["digest"]
    assert report["signature"]["digest"] == second.report["signature"]["digest"]
    assert report["same_signature_count"] == 1
  end

  test "5. two shaping reports select reshape_scope and only name that group" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]
    assert {:error, _} = Workspace.build!(control, opts)
    real = hd(reports(control)).report

    base = %{
      "intent_id" => real["intent_id"],
      "approved_package_digest" => real["approved_package_digest"],
      "category" => "cannot-comply",
      "class" => "shaping",
      "counts_toward" => "item",
      "next_action" => "reshape_scope",
      "signature" => %{
        "digest" => "hand-shaping",
        "target" => "cannot-comply",
        "first_failure" => "cannot-comply",
        "source" => "stop"
      }
    }

    path_a = report!(control, "shaping-a", Map.put(base, "stopped_at", timestamp(-2)))
    path_b = report!(control, "shaping-b", Map.put(base, "stopped_at", timestamp(-1)))
    marker = Workspace.tmp_dir!("shaping-marker") |> Path.join("launched")

    sentinel =
      Workspace.fake!(
        Workspace.tmp_dir!("shaping-sentinel"),
        "sentinel",
        "#!/bin/sh\ntouch #{marker}\nexit 1\n"
      )

    assert {:error, refusal} = Workspace.build!(control, harness: sentinel)
    assert refusal =~ "next action: reshape_scope"
    assert refusal =~ "first failure: cannot-comply"
    assert refusal =~ "signature: hand-shaping"
    assert refusal =~ "failure reports: #{path_a}, #{path_b}"
    refute refusal =~ real["build_id"]
    refute File.exists?(marker)
  end

  test "6. different signatures and environment counts do not preempt the next Build" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]
    assert {:error, _} = Workspace.build!(control, opts)
    real = hd(reports(control)).report

    item = fn digest, id ->
      report!(control, id, %{
        "intent_id" => real["intent_id"],
        "approved_package_digest" => real["approved_package_digest"],
        "counts_toward" => "item",
        "class" => "item",
        "stopped_at" => timestamp(1),
        "signature" => %{
          "digest" => digest,
          "target" => "check",
          "first_failure" => "check",
          "source" => "tail"
        }
      })
    end

    _ = item.("other-1", "other-1")
    _ = item.("other-2", "other-2")

    env = fn id ->
      report!(control, id, %{
        "intent_id" => real["intent_id"],
        "approved_package_digest" => real["approved_package_digest"],
        "counts_toward" => "environment",
        "class" => "environment",
        "stopped_at" => timestamp(2),
        "signature" => %{
          "digest" => "env-same",
          "target" => "environment",
          "first_failure" => "environment",
          "source" => "stop"
        }
      })
    end

    _ = env.("env-1")
    _ = env.("env-2")

    assert {:error, message} = Workspace.build!(control, opts)
    assert message =~ "category: offline-exhausted"
    refute String.starts_with?(message, "Build refused")
    assert length(reports(control)) == 6
  end

  test "7. readiness refusal, clear, recurrence, and exact environment paths" do
    control = Workspace.create!(route: :claude)
    claude_root = Workspace.claude_root!()
    on_exit(fn -> File.rm_rf(control) end)

    Workspace.write_intent!(control, "second-intent",
      intent_id: "01a0c467-0000-7000-8000-00000000b2e2"
    )

    builds = fn slug, logged_out, extra ->
      cwd = Workspace.tmp_dir!("environment-cwd")

      result =
        Workspace.build!(
          control,
          Keyword.merge(claude_opts(claude_root, cwd, logged_out, extra), slug: slug)
        )

      {result, cwd}
    end

    {r1_result, cwd1} = builds.("workspace-fixture", true, [])
    {r2_result, cwd2} = builds.("second-intent", true, [])
    {r3_result, cwd3} = builds.("workspace-fixture", true, [])

    for result <- [r1_result, r2_result, r3_result] do
      assert {:error, message} = result
      assert message =~ "category: environment"
    end

    assert probe_lines(cwd1) == []
    assert probe_lines(cwd2) == []
    assert probe_lines(cwd3) == []
    [p1, p2, p3] = reports(control)
    before = admission_counts(control)

    {r4_result, cwd4} = builds.("workspace-fixture", true, [])
    assert {:error, refusal} = r4_result
    assert refusal =~ "Build refused (environment breaker): 3 environment stops in a row"
    assert refusal =~ "readiness:"
    assert refusal =~ "harness claude is not ready:"
    assert refusal =~ "Run mix kogen.claude.login"

    assert refusal =~
             "failure reports: #{p1.path} (mix kogen.claude.login), #{p2.path} (mix kogen.claude.login), #{p3.path} (mix kogen.claude.login)"

    assert probe_lines(cwd4) == ["argv: auth status"]
    assert admission_counts(control) == before
    assert report_paths(control) == [p1.path, p2.path, p3.path]

    tail = write_tail!("revoked-token", "xfjcrm76_claude_oauth_revoked.json")
    {r5_result, cwd5} = builds.("workspace-fixture", false, [{"FAKE_CLAUDE_FAIL_TAIL", tail}])
    assert {:error, login_rejected} = r5_result

    assert String.starts_with?(
             login_rejected,
             "developer: claude login rejected (401) (class environment)"
           )

    assert probe_lines(cwd5) == ["argv: auth status"]
    clear = clear_for_slug!(control, "workspace-fixture")
    assert clear["schema_version"] == 1
    assert clear["reason"] == "readiness"
    assert clear["reports"] == [p1.path, p2.path, p3.path]
    stopped3 = DateTime.from_iso8601(p3.report["stopped_at"]) |> elem(1)
    cleared = DateTime.from_iso8601(clear["cleared_at"]) |> elem(1)
    stopped5 = latest_report!(control)["stopped_at"] |> DateTime.from_iso8601() |> elem(1)
    assert DateTime.compare(cleared, stopped3) == :gt
    assert DateTime.compare(cleared, stopped5) == :lt

    {r6_result, cwd6} = builds.("workspace-fixture", true, [])
    {r7_result, cwd7} = builds.("workspace-fixture", true, [])
    assert {:error, m6} = r6_result
    assert {:error, m7} = r7_result
    assert m6 =~ "category: environment"
    assert m7 =~ "category: environment"
    assert probe_lines(cwd6) == []
    assert probe_lines(cwd7) == []
    [p5, p6, p7] = reports(control) |> Enum.take(-3)

    {r8_result, cwd8} = builds.("workspace-fixture", true, [])
    assert {:error, final_refusal} = r8_result
    assert final_refusal =~ "Build refused (environment breaker): 3 environment stops in a row"

    assert final_refusal =~
             "failure reports: #{p5.path} (mix kogen.claude.login), #{p6.path} (mix kogen.claude.login), #{p7.path} (mix kogen.claude.login)"

    refute final_refusal =~ p1.path
    refute final_refusal =~ p2.path
    refute final_refusal =~ p3.path
    assert probe_lines(cwd8) == ["argv: auth status"]
  end

  test "8. an item stop ends the environment run without a clear file" do
    control = Workspace.create!(route: :claude)
    claude_root = Workspace.claude_root!()
    on_exit(fn -> File.rm_rf(control) end)

    logged_out = fn extra ->
      cwd = Workspace.tmp_dir!("item-reset-cwd")
      {Workspace.build!(control, claude_opts(claude_root, cwd, true, extra)), cwd}
    end

    assert {{:error, _}, _} = logged_out.([])
    assert {{:error, _}, _} = logged_out.([])
    cwd3 = Workspace.tmp_dir!("item-reset-offline")

    assert {:error, item_message} =
             Workspace.build!(
               control,
               claude_opts(claude_root, cwd3, false, [{"FAKE_CHECK_FAIL_ALWAYS", "1"}])
             )

    assert item_message =~ "category: offline-exhausted"
    {_, cwd4} = logged_out.([])
    {_, cwd5} = logged_out.([])
    {result6, cwd6} = logged_out.([])
    assert {:error, env_message} = result6
    assert env_message =~ "category: environment"
    assert probe_lines(cwd4) == []
    assert probe_lines(cwd5) == []
    assert probe_lines(cwd6) == []
    assert clear_files(control) == []
  end

  test "9. a published Build clears a non-empty environment run" do
    control = Workspace.create!(route: :claude)
    claude_root = Workspace.claude_root!()
    on_exit(fn -> File.rm_rf(control) end)

    Workspace.write_intent!(control, "second-intent",
      intent_id: "01a0c467-0000-7000-8000-00000000b2e2"
    )

    build = fn slug, logged_out ->
      cwd = Workspace.tmp_dir!("published-clear-cwd")

      {Workspace.build!(
         control,
         Keyword.merge(claude_opts(claude_root, cwd, logged_out), slug: slug)
       ), cwd}
    end

    assert {{:error, _}, _} = build.("workspace-fixture", true)
    assert {{:error, _}, _} = build.("workspace-fixture", true)
    {published, published_cwd} = build.("second-intent", false)
    assert published == :ok
    assert probe_lines(published_cwd) == []
    clear = clear_for_slug!(control, "second-intent")
    assert clear["reason"] == "published"
    [p1, p2] = reports(control) |> Enum.take(2)
    assert clear["reports"] == [p1.path, p2.path]

    for _ <- 1..3 do
      {result, cwd} = build.("workspace-fixture", true)
      assert {:error, message} = result
      assert message =~ "category: environment"
      refute String.starts_with?(message, "Build refused")
      assert probe_lines(cwd) == []
    end
  end

  test "10. provider reports are skipped while the environment run continues" do
    control = Workspace.create!(route: :claude)
    claude_root = Workspace.claude_root!()
    on_exit(fn -> File.rm_rf(control) end)

    build = fn logged_out, extra ->
      cwd = Workspace.tmp_dir!("provider-skip-cwd")
      {Workspace.build!(control, claude_opts(claude_root, cwd, logged_out, extra)), cwd}
    end

    assert {{:error, _}, _} = build.(true, [])
    assert {{:error, _}, _} = build.(true, [])
    tail = write_tail!("provider-limit", "be_n9crq_claude_session_limit.json")
    {provider_result, provider_cwd} = build.(false, [{"FAKE_CLAUDE_FAIL_TAIL", tail}])
    assert {:error, provider_message} = provider_result
    assert provider_message =~ "category: provider"
    provider = reports(control) |> List.last()
    assert provider.report["counts_toward"] == nil
    {environment_result, _cwd4} = build.(true, [])
    assert {:error, _} = environment_result
    [p1, p2, provider, p4] = reports(control)
    assert provider.report["build_id"] != p1.report["build_id"]
    assert provider.report["build_id"] != p2.report["build_id"]
    assert provider.report["build_id"] != p4.report["build_id"]
    {refused, cwd5} = build.(true, [])
    assert {:error, refusal} = refused
    assert refusal =~ "Build refused (environment breaker): 3 environment stops in a row"

    assert refusal =~
             "failure reports: #{p1.path} (mix kogen.claude.login), #{p2.path} (mix kogen.claude.login), #{p4.path} (mix kogen.claude.login)"

    refute refusal =~ provider.path
    assert probe_lines(provider_cwd) == []
    assert probe_lines(cwd5) == ["argv: auth status"]
  end

  test "11. a published Build with no environment run writes no clear file" do
    control = Workspace.create!(route: :claude)
    claude_root = Workspace.claude_root!()
    on_exit(fn -> File.rm_rf(control) end)
    cwd = Workspace.tmp_dir!("fresh-published-cwd")
    assert Workspace.build!(control, claude_opts(claude_root, cwd, false)) == :ok
    assert clear_files(control) == []
    assert probe_lines(cwd) == []
  end

  test "12. the second fresh prompt carries the exact canonical last-failure block" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]
    assert {:error, _} = Workspace.build!(control, opts)
    first = hd(reports(control)).report
    first_prompt = prompt!(first)
    refute first_prompt =~ "## First failure"

    rework =
      File.read!(
        Path.join(first["candidate"]["harness_home"], "fake-state/verification-resume-prompts")
      )

    assert rework =~ "## First failure"

    assert {:error, _} = Workspace.build!(control, opts)
    second = List.last(reports(control)).report
    second_prompt = prompt!(second)
    assert second_prompt =~ "## First failure"
    assert second_prompt =~ "- Target: #{first["signature"]["target"]}"
    assert second_prompt =~ "- First failure: #{first["signature"]["first_failure"]}"
    assert second_prompt =~ "- Error head: #{first["signature"]["error_head"]}"

    assert second_prompt =~
             "- Reproduce: run the command that `make check` runs, whole and at its normal concurrency, not the one test alone; the controller runs `make check` itself after your turn"

    assert second_prompt =~
             "Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it deterministic; an unchanged Candidate stops the Build."

    assert second_prompt =~ "Previous failure report: #{hd(reports(control)).path}"
    assert first_failure_span(second_prompt) == first_failure_span(rework)
  end

  test "13. a first Build with no report has no failure block" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]
    assert {:error, _} = Workspace.build!(control, opts)
    prompt = prompt!(latest_report!(control))
    refute prompt =~ "## First failure"
    refute prompt =~ "Previous failure report:"
  end

  test "14. another Intent and an older package cannot contribute a prompt block" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)
    opts = [harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]]
    assert {:error, _} = Workspace.build!(control, opts)

    Workspace.write_intent!(control, "second-intent",
      intent_id: "01a0c467-0000-7000-8000-00000000b2e2"
    )

    assert {:error, _} = Workspace.build!(control, Keyword.put(opts, :slug, "second-intent"))
    second_prompt = prompt!(latest_report!(control))
    refute second_prompt =~ "## First failure"
    refute second_prompt =~ "Previous failure report:"
    package = Path.join(control, ".kogen/intents/approved/workspace-fixture/intent.yaml")
    File.write!(package, File.read!(package) <> "# edited\n")
    assert {:error, _} = Workspace.build!(control, opts)
    edited_prompt = prompt!(latest_report!(control))
    refute edited_prompt =~ "## First failure"
    refute edited_prompt =~ "Previous failure report:"
  end

  test "15. a stop-signature report does not add a prompt block" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)

    assert {:error, cannot_comply} =
             Workspace.build!(control,
               harness: Workspace.support("fake_codex_simple_accept"),
               env: [
                 {"FAKE_JEV_ANSWERS",
                  ~s({"objection:scenario:fixture-scenario":["objection",0.99]})}
               ]
             )

    stop_report = latest_report!(control)
    assert cannot_comply =~ "cannot-comply"
    assert stop_report["category"] == "cannot-comply"
    assert stop_report["signature"]["source"] == "stop"

    assert {:error, _} =
             Workspace.build!(control,
               harness: Workspace.support("fake_codex"),
               env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]
             )

    prompt = prompt!(latest_report!(control))
    refute prompt =~ "## First failure"
    refute prompt =~ "Previous failure report:"
  end
end
