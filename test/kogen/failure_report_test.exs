Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.FailureReportTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{FailureReport, FailureSignature}
  alias Kogen.CandidateFixture, as: Candidate
  alias Kogen.ScriptedBuildFixture, as: Scripted
  alias Kogen.WorkspaceFixture, as: Workspace

  test "writes one durable report and never overwrites it" do
    root = Path.join(System.tmp_dir!(), "kogen-report-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, path} = FailureReport.write(root, "build-1", %{"category" => "provider"})
    assert {:ok, ^path} = FailureReport.write(root, "build-1", %{"category" => "integrity"})

    assert %{"category" => "provider", "schema_version" => 1} =
             path |> File.read!() |> Jason.decode!()
  end

  test "classifies terminal categories and produces stable stop signatures" do
    assert {"provider", "provider_wait"} = FailureReport.classify("provider")
    assert {"environment", "environment"} = FailureReport.classify("environment")
    first = FailureSignature.for_stop("integrity", "broken input")
    assert first["digest"] == FailureSignature.for_stop("integrity", "broken input")["digest"]
  end

  test "category table keeps the approved classes and excludes continuation rows" do
    assert {"item", "rebuild"} = FailureReport.classify("offline-exhausted")
    assert {"shaping", "reshape_scope"} = FailureReport.classify("cannot-comply")
    assert {"environment", "inspect"} = FailureReport.classify("accepted-unpublished")
    assert {"provider", "provider_wait"} = FailureReport.classify("provider")
    assert FailureReport.counts_toward("provider") == nil
    refute FailureReport.classify("interrupted") == {"interrupted", "continue"}
  end

  test "the category table is exhaustive and exposes counting semantics" do
    item_categories = ~w(
      verification-exhausted offline-exhausted unchanged-candidate outer-allowance-exhausted
      guard-violation protected-path git-policy integrity review-failure
    )

    for category <- item_categories do
      assert FailureReport.classify(category) == {"item", "rebuild"}
      assert FailureReport.counts_toward(category) == "item"
    end

    assert FailureReport.classify("cannot-comply") == {"shaping", "reshape_scope"}

    for category <- ~w(environment provider-failure write-boundary admission publication-failed) do
      assert FailureReport.classify(category) == {"environment", "environment"}
      assert FailureReport.counts_toward(category) == "environment"
    end

    assert FailureReport.classify("accepted-unpublished") == {"environment", "inspect"}
    assert FailureReport.classify("provider") == {"provider", "provider_wait"}
    assert FailureReport.counts_toward("provider") == nil

    for forbidden <- ~w(interrupted publication-interrupted session-lost) do
      refute FailureReport.classify(forbidden) == {forbidden, "continue"}
    end
  end

  test "record_failure binds the final record bytes and control-relative path" do
    root =
      Path.join(System.tmp_dir!(), "kogen-report-context-#{System.unique_integer([:positive])}")

    path = Path.join(root, ".kogen/runtime/scenario-tracking/build-1/record.json")
    File.mkdir_p!(Path.dirname(path))

    bytes =
      Jason.encode!(%{
        "intent" => %{"slug" => "demo", "id" => "intent-1"},
        "approved_package_digest" => "pkg-1",
        "attempts" => [%{"failure_signatures" => [%{"digest" => "sig-1"}], "stop_class" => nil}]
      })

    File.write!(path, bytes)
    on_exit(fn -> File.rm_rf(root) end)

    ctx = %{
      control: root,
      slug: "demo",
      tracking: %{path: path, bytes: bytes, record: Jason.decode!(bytes)},
      candidate: nil
    }

    assert {:ok, report_path} = FailureReport.record_failure(ctx, "offline-exhausted", "failed")
    report = report_path |> File.read!() |> Jason.decode!()
    assert report["build_id"] == "build-1"
    assert report["record"] == ".kogen/runtime/scenario-tracking/build-1/record.json"
    assert report["record_sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert report["stopped_at"] =~ ~r/\.\d+Z$/
  end

  test "same signature counts only matching intent and approved package" do
    root =
      Path.join(System.tmp_dir!(), "kogen-report-count-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    signature = %{"digest" => "same-digest", "target" => "check"}

    for {build_id, intent_id, package} <- [
          {"old-same", "intent-1", "pkg-1"},
          {"old-intent", "intent-2", "pkg-1"},
          {"old-package", "intent-1", "pkg-2"}
        ] do
      dir = Path.join(root, ".kogen/runtime/scenario-tracking/#{build_id}")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "failure-report.json"),
        Jason.encode!(%{
          "intent_id" => intent_id,
          "approved_package_digest" => package,
          "signature" => signature
        })
      )
    end

    build = "new-build"
    record_path = Path.join(root, ".kogen/runtime/scenario-tracking/#{build}/record.json")
    File.mkdir_p!(Path.dirname(record_path))

    record = %{
      "intent" => %{"slug" => "demo", "id" => "intent-1"},
      "approved_package_digest" => "pkg-1",
      "attempts" => [%{"failure_signatures" => [signature]}]
    }

    bytes = Jason.encode!(record)
    File.write!(record_path, bytes)

    assert {:ok, report_path} =
             FailureReport.record_failure(
               %{control: root, tracking: %{path: record_path, bytes: bytes, record: record}},
               "offline-exhausted",
               "failed"
             )

    assert report_path |> File.read!() |> Jason.decode!() |> Map.fetch!("same_signature_count") ==
             2
  end

  test "two offline exhaustion Builds write final reports and count the same signature" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)

    for expected <- [1, 2] do
      assert {:error, message} =
               Workspace.build!(control,
                 harness: Workspace.support("fake_codex"),
                 env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]
               )

      report = latest_report!(control)
      assert_report!(control, report, message, "offline-exhausted")
      assert report["class"] == "item"
      assert report["counts_toward"] == "item"
      assert report["same_signature_count"] == expected
      assert report["next_action"] == if(expected == 1, do: "rebuild", else: "reshape_details")

      assert report["signature"] ==
               List.last(List.last(Candidate.record(control)["attempts"])["failure_signatures"])
    end
  end

  test "readiness and admission stops write environment reports" do
    root =
      Path.join(System.tmp_dir!(), "kogen-readiness-report-#{System.unique_integer([:positive])}")

    record_path = Path.join(root, ".kogen/runtime/scenario-tracking/build-1/record.json")
    File.mkdir_p!(Path.dirname(record_path))
    record = %{"intent" => %{"slug" => "demo", "id" => "intent-1"}, "attempts" => []}
    bytes = Jason.encode!(record)
    File.write!(record_path, bytes)
    on_exit(fn -> File.rm_rf(root) end)

    ctx = %{
      control: root,
      slug: "demo",
      tracking: %{path: record_path, bytes: bytes, record: record},
      candidate: nil
    }

    reason =
      "developer and reviewer and expert harness claude is not ready: Run mix kogen.claude.login"

    assert {:ok, path} = FailureReport.record_failure(ctx, "environment", reason)
    report = path |> File.read!() |> Jason.decode!()
    assert report["stop_class"] == nil
    assert report["next_command"] == "mix kogen.claude.login"
  end

  test "Jev cannot-comply, missing deps, and publication refusal each write their terminal report" do
    control = Workspace.create!(deps: false)
    on_exit(fn -> File.rm_rf(control) end)

    assert {:error, missing_deps} =
             Workspace.build!(control, harness: Workspace.support("fake_codex_simple_accept"))

    report = latest_report!(control)
    assert_report!(control, report, missing_deps, "admission")
    assert report["class"] == "environment"
    assert report["candidate"] == nil

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

    report = latest_report!(control)
    assert_report!(control, report, cannot_comply, "cannot-comply")
    assert report["class"] == "shaping"
    assert report["next_action"] == "reshape_scope"

    role =
      Workspace.waiting_role!(
        Workspace.tmp_dir!("report-publication-role"),
        Workspace.support("fake_codex_simple_accept")
      )

    task =
      Task.async(fn ->
        Workspace.build!(control, harness: role)
      end)

    home = Workspace.await_waiting!(control)
    File.write!(Path.join(control, "README.md"), "changed while the Candidate was running\n")
    File.write!(Path.join(home, "go"), "")
    assert {:error, publication} = Task.await(task, 180_000)

    report = latest_report!(control)
    assert_report!(control, report, publication, "accepted-unpublished")
    assert report["class"] == "environment"
    assert report["next_action"] == "inspect"

    owner =
      Enum.find(
        Workspace.owner_records(control),
        &String.starts_with?(&1["status"], "accepted-unpublished:")
      )

    assert owner
  end

  test "a pre-admission route refusal writes neither a record nor a report" do
    control = Workspace.create!()
    on_exit(fn -> File.rm_rf(control) end)

    assert {:error, reason} = Workspace.build!(control, route: "missing-route")
    assert reason =~ "unknown route"

    assert Path.wildcard(Path.join(control, ".kogen/runtime/scenario-tracking/*/record.json")) ==
             []

    assert Path.wildcard(
             Path.join(control, ".kogen/runtime/scenario-tracking/*/failure-report.json")
           ) == []
  end

  test "a Claude login rejection is an environment stop with one Developer invocation" do
    control = Workspace.create!(route: :claude)
    on_exit(fn -> File.rm_rf(control) end)
    tail = fixture_output!("xfjcrm76_claude_oauth_revoked.json")
    tail_path = Path.join(Workspace.tmp_dir!("login-tail"), "tail.jsonl")
    File.write!(tail_path, tail)

    assert {:error, reason} =
             Workspace.build!(control,
               harness: Workspace.support("fake_claude"),
               env: [
                 {"FAKE_CLAUDE_FAIL_TAIL", tail_path},
                 {"KOGEN_CLAUDE_ROOT", Workspace.claude_root!()}
               ]
             )

    report = latest_report!(control)
    assert_report!(control, report, reason, "environment")

    assert String.starts_with?(
             reason,
             "developer: claude login rejected (401) (class environment)"
           )

    assert reason =~ "run `mix kogen.claude.login`"
    assert report["stop_class"] == "environment"
    assert report["next_command"] == "mix kogen.claude.login"
    [owner] = Workspace.owner_records(control)
    assert owner["status"] == "stopped: environment"

    harness_log = Path.join(report["candidate"]["harness_home"], "fake-state/fake-harness-log")

    launches =
      harness_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.count(
        &(String.starts_with?(&1, "argv:") and not String.contains?(&1, " auth status"))
      )

    assert launches == 1
  end

  test "usage-limited Developer stop keeps the provider class and session" do
    dir = Scripted.fixture!()
    tail = fixture_output!("be_n9crq_claude_session_limit.json")

    assert {:error, message} =
             Scripted.run(dir, provider_fail: ["developer-1"], provider_tail: tail)

    report = latest_report!(dir)
    assert_report!(dir, report, message, "provider")
    assert report["next_action"] == "provider_wait"
    assert report["counts_toward"] == nil
    assert report["developer_session_id"] == "developer-session"
  end

  test "failed cycle signature is recorded before the resumed Developer stops" do
    dir = Scripted.fixture!()
    tail = fixture_output!("be_n9crq_claude_session_limit.json")

    assert {:error, _message} =
             Scripted.run(dir,
               fail_first: [1],
               provider_fail: ["developer-2"],
               provider_tail: tail
             )

    attempt = dir |> Scripted.record!() |> Map.fetch!("attempts") |> List.last()
    assert [signature] = attempt["cycle_signatures"]
    assert signature["target"] == "check"
    refute Map.has_key?(attempt, "failure_signatures")
    assert latest_report!(dir)["signature"] == signature

    prompt = File.read!(Candidate.fake_state(dir, "developer-invocation-2-prompt"))
    assert prompt =~ "## First failure"
    assert prompt =~ signature["first_failure"]

    assert prompt =~
             "Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it deterministic; an unchanged Candidate stops the Build."
  end

  defp latest_report!(control) do
    path =
      control
      |> Path.join(".kogen/runtime/scenario-tracking/*/failure-report.json")
      |> Path.wildcard()
      |> Enum.max_by(&File.stat!(&1).mtime)

    path |> File.read!() |> Jason.decode!()
  end

  defp assert_report!(control, report, message, category) do
    record_path =
      control
      |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
      |> Path.wildcard()
      |> Enum.max_by(&File.stat!(&1).mtime)

    report_path = Path.join(Path.dirname(record_path), "failure-report.json")
    assert report["schema_version"] == 1
    assert report["category"] == category
    assert report["build_id"] == Path.basename(Path.dirname(record_path))
    assert report["record"] == Path.relative_to(record_path, control)
    record = File.read!(record_path) |> Jason.decode!()
    assert report["slug"] == record["intent"]["slug"]
    assert report["intent_id"] == record["intent"]["id"]
    assert report["approved_package_digest"] == record["approved_package_digest"]

    assert report["record_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, File.read!(record_path)), case: :lower)

    assert report["slug"]
    assert report["intent_id"]
    assert report["approved_package_digest"]
    assert report["stopped_at"] =~ ~r/\.\d+Z$/
    assert Map.has_key?(report, "candidate_build_id")
    assert Map.has_key?(report, "stop_class")
    assert Map.has_key?(report, "signature")
    assert Map.has_key?(report, "same_signature_count")
    assert Map.has_key?(report, "developer_session_id")
    assert Map.has_key?(report, "reason")
    assert Map.has_key?(report, "continues")
    assert Map.has_key?(report, "budget_state")
    assert Map.has_key?(report, "published")
    assert Map.has_key?(report, "continuable")

    assert [_, reported_path] =
             Regex.run(~r/category: #{category}; failure report: (.+?); next action:/, message)

    assert File.stat!(reported_path).inode == File.stat!(report_path).inode
    assert message =~ "next action: #{report["next_action"]}"

    assert File.ls!(Path.dirname(report_path))
           |> Enum.count(&String.contains?(&1, "failure-report")) == 1

    assert Path.wildcard(Path.join(Path.dirname(report_path), ".failure-report-*.tmp")) == []
  end

  defp fixture_output!(name) do
    Path.join([Workspace.project_root(), "test/support/provider_tails", name])
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("output")
  end
end
