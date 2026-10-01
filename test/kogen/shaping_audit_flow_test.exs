Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingAuditFlowTest do
  @moduledoc "Questions and audit state transitions for the Shaping audit."
  use Kogen.IsolatedCase, async: true

  @project_root Path.expand("../..", __DIR__)

  alias Kogen.ShapingAudit.{Finding, Fixture, Package, Questions, Report}

  @fixtures Path.join(@project_root, "test/support/shaping_audit/packages/flow")

  defp questions!(state) do
    Path.join([@fixtures, state, "questions.md"]) |> File.read!() |> Questions.parse()
  end

  defp files(state) do
    Path.join([@fixtures, state, "*"])
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.basename(path), File.read!(path)} end)
  end

  test "open Ask the Shaper entries put the audit in asking state" do
    questions = questions!("asking-no-answers")
    assert Questions.state(questions) == :asking
    assert is_list(Questions.findings(questions, files("asking-no-answers")))
  end

  test "repeated recognized sections merge and a later empty ask cannot erase open questions" do
    questions =
      Questions.parse("""
      ## Ask the Shaper

      1. Keep the original behavior? Recommendation: retain it. Evidence: "existing contract".

      ## Ask the Shaper

      ## Shaper answers
      none yet

      ## Ask the Shaper

      2. Should the new path be public? Recommendation: keep it private. Evidence: unproven — confirm with the Shaper.
      """)

    asks = Questions.entries(questions, "Ask the Shaper")

    assert Enum.map(asks, & &1.number) == [1, 2]
    assert Questions.state(questions) == :asking
    assert Questions.findings(questions, ["questions.md"]) == []
  end

  test "question evidence and recommendation defects become findings" do
    questions = questions!("asking-no-evidence")
    findings = Questions.findings(questions, files("asking-no-evidence"))
    assert Enum.any?(findings, &(&1["rule"] == "recommendation-without-evidence"))
  end

  test "technical wording remains available to the Jev question gate" do
    questions = questions!("asking-technical")

    assert Enum.any?(Questions.entries(questions, "Ask the Shaper"), fn entry ->
             String.contains?(String.downcase(entry.text), "genserver")
           end)

    assert Questions.state(questions) == :asking
  end

  test "answered, left-undecided and settled sections are autonomous" do
    for state <- ["left-undecided", "ready", "not-ready"] do
      refute Questions.state(questions!(state)) == :asking
    end
  end

  test "an assumed entry without its undo reason is reported" do
    questions = questions!("assumed-without-reason")
    findings = Questions.findings(questions, files("assumed-without-reason"))
    assert Enum.any?(findings, &(&1["rule"] == "assumption-without-reason"))
  end

  defp flow_checkout! do
    root = Fixture.repo!(second_commit: false, working_tree: false, prior_failures: false)
    File.mkdir_p!(Path.join(root, "test/kogen"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: true\nend\n")
    File.write!(Path.join(root, "test/kogen/demo_test.exs"), "assert true\n")
    {_, 0} = System.cmd("git", ["add", "lib/demo.ex", "test/kogen/demo_test.exs"], cd: root)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "flow: demo"], cd: root)
    root
  end

  defp audit_flow!(state) do
    root = flow_checkout!()
    package_rel = Fixture.add_draft!(root, state, source: "packages/flow")
    on_exit(fn -> File.rm_rf!(root) end)

    env =
      Fixture.audit_env!(root)
      |> then(fn env ->
        env
      end)

    previous_answers = System.get_env("FAKE_JEV_ANSWERS")

    if state == "asking-technical" do
      System.put_env("FAKE_JEV_ANSWERS", Jason.encode!(%{"gate" => ["technical", 1.0]}))
    end

    exit_code = Kogen.ShapingAudit.main(["--auditor", "flow-demo"], root: root, env: env)

    if previous_answers,
      do: System.put_env("FAKE_JEV_ANSWERS", previous_answers),
      else: System.delete_env("FAKE_JEV_ANSWERS")

    {:ok, loaded} = Package.load(root, package_rel)
    {:ok, report} = Report.read(root, "flow-demo", loaded.revision)
    {exit_code, report, root}
  end

  test "main/2 audits every approved questions.md state with the real deterministic layer" do
    cases = [
      {"asking-no-answers", 1, "asking", []},
      {"asking-technical", 1, "asking", []},
      {"asking-no-evidence", 1, "asking", ["recommendation-without-evidence 1"]},
      {"asking-second-round", 1, "asking", []},
      {"left-undecided", 0, "ready", []},
      {"assumed-without-reason", 1, "not_ready", ["assumption-without-reason 1"]},
      {"not-ready", 1, "not_ready", ["unguarded-affected-path"]},
      {"ready", 0, "ready", []}
    ]

    for {state, code, readiness, required_ids} <- cases do
      {^code, report, _root} = audit_flow!(state)
      assert report["state"] == if(readiness == "asking", do: "asking", else: "autonomous")
      assert report["readiness"] == readiness

      assert report["layers"]["deterministic"]["status"] ==
               if(readiness == "asking", do: "skipped", else: "ok")

      ids = Enum.map(report["findings"], & &1["id"])

      assert Enum.all?(required_ids, fn required ->
               Enum.any?(ids, &String.starts_with?(&1, required))
             end),
             "#{state}: #{inspect(ids)}"

      if state in ["asking-no-answers", "asking-second-round"] do
        assert report["findings"] == []
        assert report["layers"]["auditor"]["status"] == "skipped"
      end
    end
  end

  test "real flow reports preserve question sections and do not mutate package bytes" do
    {0, report, root} = audit_flow!("ready")
    assert length(report["questions"]["sections"]["Assumed"]) == 1
    assert length(report["questions"]["sections"]["Left undecided"]) == 1
    refute Enum.any?(report["questions"]["sections"], fn {_name, entries} -> entries == [] end)

    package = Path.join(root, ".kogen/intents/drafts/flow-demo")

    assert File.read!(Path.join(package, "questions.md")) ==
             File.read!(Path.join(@fixtures, "ready/questions.md"))
  end

  # The block reason INTENT.md states, computed from report.json independently.
  defp expected_reason(path) do
    report = path |> File.read!() |> Jason.decode!()

    lines =
      report["findings"]
      |> Enum.filter(&Finding.open_blocking?/1)
      |> Enum.map(&"- #{&1["id"]} (route: #{&1["route"] || "none"}): #{&1["message"]}")

    advisory = Enum.count(report["findings"], &(&1["severity"] == "advisory"))

    Enum.join(
      ["blocking findings:" | lines] ++ ["advisory: #{advisory}", "report: #{path}"],
      "\n"
    )
  end

  defp hook_stop!(state) do
    root = flow_checkout!()
    package_rel = Fixture.add_draft!(root, state, source: "packages/flow")
    on_exit(fn -> File.rm_rf(root) end)
    t = 1_790_000_000_000
    output = Path.join(root, "hook-output.json")

    env =
      root
      |> Fixture.audit_env!()
      |> Map.merge(%{
        "KOGEN_ROLE" => "shaping",
        "KOGEN_SHAPING_INTENT_ID" => "018f2a3b-0000-7000-8000-000000000003",
        "KOGEN_SHAPING_ROUTE" => "codex",
        "KOGEN_SHAPING_LAUNCH_ID" => "01a0c44e-9740-7000-8000-000000000001",
        "KOGEN_SHAPING_SKIP_KEY" => "k1",
        "KOGEN_SHAPING_HOOK_OUTPUT" => output
      })

    env =
      if state == "asking-technical" do
        answers = Jason.encode!(%{"gate" => ["technical", 1.0]})
        System.put_env("FAKE_JEV_ANSWERS", answers)
        Map.put(env, "FAKE_JEV_ANSWERS", answers)
      else
        env
      end

    {:ok, reads} = Agent.start_link(fn -> [t, t + 1_500] end)

    clock = fn ->
      DateTime.from_unix!(Agent.get_and_update(reads, &{hd(&1), tl(&1)}), :millisecond)
    end

    assert Kogen.ShapingAudit.main(["--stop-hook"],
             root: root,
             env: env,
             stdin: "",
             clock: clock
           ) == 0

    System.delete_env("FAKE_JEV_ANSWERS")
    assert Agent.get(reads, & &1) == []
    decision = output |> File.read!() |> Jason.decode!()

    [line] =
      root
      |> Path.join(".kogen/runtime/shaping-audits/flow-demo/hook.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    {:ok, loaded} = Package.load(root, package_rel)
    assert line["revision"] == loaded.revision

    path =
      Path.join([root, ".kogen/runtime/shaping-audits/flow-demo", loaded.revision, "report.json"])

    {decision, line, path}
  end

  test "H25 the hook decides each flow package as front-loaded-questions requires" do
    # 0x01a0c44e9740 is t - 120_000 ms, so the launch reads 2.0 min.
    assert 0x01A0C44E9740 == 1_790_000_000_000 - 120_000

    elapsed =
      "elapsed: launch 2.0 min, chain 0.0 min, audit 0.0 min (total 0.0 min), budget 15.0 min"

    undecided =
      "Left undecided:\n- Whether to support dark mode. Recommendation: defer, revisit after v1."

    for state <- ["asking-no-answers", "asking-second-round"] do
      {decision, line, _path} = hook_stop!(state)
      assert decision == %{"continue" => true}, state

      assert {line["kind"], line["decision"], line["readiness"], line["blocking"]} ==
               {"asking", "allow", "asking", []},
             state
    end

    for {state, ids, route} <- [
          {"asking-technical",
           ["technical-question-to-shaper 1", "technical-question-to-shaper 2"], "controller"},
          {"asking-no-evidence", ["recommendation-without-evidence 1"], nil},
          {"assumed-without-reason", ["assumption-without-reason 1"], nil},
          {"not-ready", ["unguarded-affected-path lib/demo.ex"], nil}
        ] do
      {decision, line, path} = hook_stop!(state)
      assert decision == %{"decision" => "block", "reason" => expected_reason(path)}, state

      assert {line["kind"], line["decision"], line["blocking"], line["chain_blocks"]} ==
               {"blocked", "block", ids, 1},
             state

      report = path |> File.read!() |> Jason.decode!()
      open = Enum.filter(report["findings"], &Finding.open_blocking?/1)
      assert Enum.map(open, & &1["id"]) == ids, state
      if route, do: assert(Enum.map(open, & &1["route"]) == [route, route], state)
    end

    {decision, line, path} = hook_stop!("left-undecided")

    assert decision == %{
             "continue" => true,
             "systemMessage" =>
               "ready: #{path}\n#{elapsed}\nAssumed: none\n#{undecided}\nNot audited by the auditor: none"
           }

    assert {line["kind"], line["decision"]} == {"ready", "allow"}

    {decision, line, path} = hook_stop!("ready")

    assert decision == %{
             "continue" => true,
             "systemMessage" =>
               "ready: #{path}\n#{elapsed}\nAssumed:\n- The button keeps its current size. Reason: the " <>
                 "Shaper asked only about colour. Undo: resize it in a follow-up Intent.\n" <>
                 "#{undecided}\nNot audited by the auditor: none"
           }

    assert {line["kind"], line["decision"]} == {"ready", "allow"}
  end

  # -- reuse, checkpoint scope, serialization -----------------------------------

  defp slug_runtime(root), do: Path.join(root, ".kogen/runtime/shaping-audits/flow-demo")

  defp scheduled_draft!(state, env_extra \\ %{}) do
    root = flow_checkout!()
    package_rel = Fixture.add_draft!(root, state, source: "packages/flow")
    on_exit(fn -> File.rm_rf(root) end)
    env = root |> Fixture.audit_env!() |> Map.merge(env_extra)
    {root, package_rel, env}
  end

  defp run_audit(root, env, extra \\ %{}) do
    Kogen.ShapingAudit.audit(
      root,
      Map.merge(%{slug: "flow-demo", auditor: true, env: env, opts: []}, extra)
    )
  end

  defp change_audit_revision!(root, package_rel, marker) do
    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# #{marker}\n", [:append])
  end

  defp auditor_launches(root) do
    root
    |> slug_runtime()
    |> Path.join("auditor/*.json")
    |> Path.wildcard()
    |> Enum.count(fn path -> (path |> File.read!() |> Jason.decode!())["counted"] != false end)
  end

  defp jev_requests(env) do
    env["FAKE_JEV_LOG_DIR"] |> Path.join("request-*.json") |> Path.wildcard() |> length()
  end

  defp clear_fake_logs!(env) do
    File.rm_rf!(env["FAKE_AUDITOR_LOG_DIR"])
    File.rm_rf!(env["FAKE_JEV_LOG_DIR"])
  end

  test "reuse: true returns a current full report with no layer call; a changed revision re-audits" do
    {root, package_rel, env} = scheduled_draft!("ready")

    {:ok, first, path} = run_audit(root, env)
    assert {first["scope"], first["readiness"]} == {"full", "ready"}
    assert auditor_launches(root) == 1
    assert File.dir?(env["FAKE_AUDITOR_LOG_DIR"])

    clear_fake_logs!(env)
    bytes = File.read!(path)
    File.rm!(Path.join(Path.dirname(path), "report.md"))

    assert {:ok, reused, ^path} = run_audit(root, env, %{reuse: true})
    assert reused["revision"] == first["revision"]
    assert reused["readiness"] == "ready"
    assert File.read!(path) == bytes
    refute File.exists?(Path.join(Path.dirname(path), "report.md"))
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
    refute File.exists?(env["FAKE_JEV_LOG_DIR"])
    assert auditor_launches(root) == 1

    # Control: the same call on a changed revision runs the layers again.
    File.write!(Path.join([root, package_rel, "questions.md"]), "\n2. Another settled item.\n", [
      :append
    ])

    assert {:ok, changed, changed_path} = run_audit(root, env, %{reuse: true})
    assert changed["revision"] != first["revision"]
    assert changed_path != path
    assert File.exists?(Path.join(Path.dirname(changed_path), "report.md"))
    assert changed["layers"]["deterministic"]["status"] == "ok"
  end

  test "reuse: true never returns a report for another HEAD" do
    {root, _package_rel, env} = scheduled_draft!("ready")
    {:ok, first, path} = run_audit(root, env)

    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: false\nend\n")
    {_, 0} = System.cmd("git", ["commit", "-q", "-am", "flow: move head"], cd: root)

    assert {:ok, second, ^path} = run_audit(root, env, %{reuse: true})
    assert second["revision"] == first["revision"]
    refute second["head"] == first["head"]
  end

  test "checkpoint scope runs no auditor and no Jev, is never ready, and is never reused as full" do
    {root, _package_rel, env} = scheduled_draft!("ready")

    assert {:ok, checkpoint, path} = run_audit(root, env, %{scope: :checkpoint})
    assert checkpoint["scope"] == "checkpoint"
    assert checkpoint["readiness"] == "not_ready"
    assert checkpoint["layers"]["jev"] == %{"status" => "skipped", "reason" => "checkpoint scope"}
    assert checkpoint["layers"]["deterministic"]["status"] == "ok"
    assert checkpoint["layers"]["auditor"]["launched"] == false
    assert Path.basename(path) == "checkpoint.json"
    assert auditor_launches(root) == 0
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
    assert jev_requests(env) == 0

    revision = checkpoint["revision"]
    assert Report.read(root, "flow-demo", revision) == {:error, :missing}
    assert {:ok, %{"scope" => "checkpoint"}} = Report.read_checkpoint(root, "flow-demo", revision)

    {:ok, head} = Kogen.Git.head_sha(root)
    assert Report.status(root, "flow-demo", revision, head, checkpoint["route"]) == :missing

    # A following full reuse audit is not satisfied by the checkpoint.
    assert {:ok, full, full_path} = run_audit(root, env, %{reuse: true})
    assert {full["scope"], full["readiness"]} == {"full", "ready"}
    assert Path.basename(full_path) == "report.json"
    assert auditor_launches(root) == 1

    # A later checkpoint never overwrites the full report.
    assert {:ok, _again, _path} = run_audit(root, env, %{scope: :checkpoint})

    assert {:ok, %{"scope" => "full", "readiness" => "ready"}} =
             Report.read(root, "flow-demo", revision)

    assert {:ok, %{"scope" => "checkpoint"}} = Report.read_checkpoint(root, "flow-demo", revision)
  end

  test "a checkpoint of an asking package reports asking" do
    {root, _package_rel, env} = scheduled_draft!("asking-no-answers")
    assert {:ok, report, _path} = run_audit(root, env, %{scope: :checkpoint})

    assert {report["scope"], report["readiness"], report["state"]} ==
             {"checkpoint", "asking", "asking"}
  end

  test "an asking-state stop runs no auditor even with reuse" do
    {root, _package_rel, env} = scheduled_draft!("asking-no-answers")
    assert {:ok, report, _path} = run_audit(root, env, %{reuse: true})
    assert {report["scope"], report["readiness"]} == {"full", "asking"}
    assert report["layers"]["auditor"]["status"] == "skipped"
    assert auditor_launches(root) == 0
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
  end

  test "two concurrent audits of one slug serialize: one auditor launch, one shared report" do
    {root, _package_rel, env} = scheduled_draft!("ready", %{"FAKE_AUDITOR_SLEEP_SECONDS" => "1"})
    File.mkdir_p!(slug_runtime(root))

    File.write!(
      Path.join(slug_runtime(root), "audit.lock"),
      Jason.encode!(%{"pid" => "2147483000", "started_at" => "Thu Jan  1 00:00:00 1970"})
    )

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> run_audit(root, env, %{reuse: true}) end) end)
      |> Task.await_many(60_000)

    assert [{:ok, a, path_a}, {:ok, b, path_b}] = results
    assert {a["revision"], a["readiness"]} == {b["revision"], b["readiness"]}
    assert path_a == path_b
    assert a["readiness"] == "ready"
    assert auditor_launches(root) == 1
    refute File.exists?(Path.join(slug_runtime(root), "audit.lock"))
  end

  test "the bounded confirmation binds revisions and serializes its single external grant" do
    {root, package_rel, env} = scheduled_draft!("ready")

    assert {:ok, first, _path} = run_audit(root, env)
    assert first["readiness"] == "ready"
    first_revision = first["revision"]
    assert auditor_launches(root) == 1

    change_audit_revision!(root, package_rel, "second revision")
    assert {:ok, second, _path} = run_audit(root, env)
    assert second["readiness"] == "ready"
    assert second["revision"] != first_revision
    assert second["layers"]["auditor"]["audited_binding"]["revision"] == second["revision"]
    assert second["layers"]["auditor"]["previous_audit"]["revision"] == first_revision
    assert second["layers"]["auditor"]["budget_state"]["normal_count"] == 2
    assert auditor_launches(root) == 2

    change_audit_revision!(root, package_rel, "third revision")
    {:ok, exhausted} = Package.load(root, package_rel)
    assert {:ok, missing, _path} = run_audit(root, env)
    assert missing["readiness"] == "not_ready"
    assert missing["layers"]["auditor"]["status"] == "missing-confirmation"
    assert missing["layers"]["auditor"]["requested_binding"]["revision"] == exhausted.revision
    assert missing["layers"]["auditor"]["previous_audit"]["revision"] == second["revision"]
    assert missing["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "available"
    assert auditor_launches(root) == 2

    previous_sleep = System.get_env("FAKE_AUDITOR_SLEEP_SECONDS")
    System.put_env("FAKE_AUDITOR_SLEEP_SECONDS", "1")

    on_exit(fn ->
      if is_nil(previous_sleep),
        do: System.delete_env("FAKE_AUDITOR_SLEEP_SECONDS"),
        else: System.put_env("FAKE_AUDITOR_SLEEP_SECONDS", previous_sleep)
    end)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> run_audit(root, env, %{confirm?: true, reuse: true}) end)
      end)
      |> Task.await_many(30_000)

    assert Enum.all?(results, fn {:ok, report, _path} -> report["readiness"] == "ready" end)
    assert auditor_launches(root) == 3

    # A full cache replay of the used grant runs no layer, including Jev.
    clear_fake_logs!(env)
    assert {:ok, cached, _path} = run_audit(root, env, %{confirm?: true, reuse: true})
    assert cached["readiness"] == "ready"
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
    refute File.exists?(env["FAKE_JEV_LOG_DIR"])
    assert auditor_launches(root) == 3

    # A direct confirmation request at the exact same revision reuses the
    # granted auditor result even when the full report itself is not reused.
    assert {:ok, reused, _path} = run_audit(root, env, %{confirm?: true})
    assert reused["layers"]["auditor"]["reused"] == true
    assert reused["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    assert auditor_launches(root) == 3

    change_audit_revision!(root, package_rel, "fourth revision")
    assert {:ok, spent, _path} = run_audit(root, env, %{confirm?: true})
    assert spent["readiness"] == "not_ready"
    assert spent["layers"]["auditor"]["status"] == "missing-confirmation"
    assert spent["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    assert auditor_launches(root) == 3
  end

  test "a failed external confirmation consumes the single grant" do
    {root, package_rel, env} = scheduled_draft!("ready")
    assert {:ok, first, _path} = run_audit(root, env)
    assert first["readiness"] == "ready"

    change_audit_revision!(root, package_rel, "second revision")
    assert {:ok, second, _path} = run_audit(root, env)
    assert second["readiness"] == "ready"
    assert auditor_launches(root) == 2

    change_audit_revision!(root, package_rel, "third revision")
    previous_message = System.get_env("FAKE_AUDITOR_MESSAGE")
    System.put_env("FAKE_AUDITOR_MESSAGE", "no-json")

    on_exit(fn ->
      if is_nil(previous_message),
        do: System.delete_env("FAKE_AUDITOR_MESSAGE"),
        else: System.put_env("FAKE_AUDITOR_MESSAGE", previous_message)
    end)

    assert {:ok, failed, _path} = run_audit(root, env, %{confirm?: true})
    assert failed["readiness"] == "not_ready"
    assert failed["layers"]["auditor"]["status"] == "unavailable"
    assert failed["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    assert auditor_launches(root) == 3

    change_audit_revision!(root, package_rel, "fourth revision")
    assert {:ok, exhausted, _path} = run_audit(root, env, %{confirm?: true})
    assert exhausted["layers"]["auditor"]["status"] == "missing-confirmation"
    assert exhausted["layers"]["auditor"]["previous_audit"]["confirmation_grant"] == true
    assert auditor_launches(root) == 3
  end

  test "prior auditor findings stay as bound diagnostics with current dispositions" do
    {root, package_rel, env} =
      scheduled_draft!("ready", %{"FAKE_AUDITOR_MESSAGE" => "three-findings"})

    previous_message = System.get_env("FAKE_AUDITOR_MESSAGE")
    System.put_env("FAKE_AUDITOR_MESSAGE", "three-findings")

    on_exit(fn ->
      if is_nil(previous_message),
        do: System.delete_env("FAKE_AUDITOR_MESSAGE"),
        else: System.put_env("FAKE_AUDITOR_MESSAGE", previous_message)
    end)

    assert {:ok, first, _path} = run_audit(root, env)
    [prior_finding | _] = first["layers"]["auditor"]["findings"]
    prior_revision = first["revision"]

    questions = Path.join([root, package_rel, "questions.md"])

    File.write!(
      questions,
      "\n## Dispositions\n\n- #{prior_finding["id"]}: not a defect — reviewed against the current package.\n",
      [:append]
    )

    assert {:ok, second, _path} = run_audit(root, env)
    assert second["layers"]["auditor"]["status"] == "ok"
    assert second["layers"]["auditor"]["previous_audit"]["revision"] == prior_revision

    assert second["layers"]["auditor"]["previous_audit"]["findings"]
           |> Enum.find(&(&1["id"] == prior_finding["id"]))
           |> get_in(["disposition", "kind"]) == "not-a-defect"

    assert Enum.any?(second["findings"], fn finding ->
             finding["id"] == prior_finding["id"] and
               get_in(finding, ["disposition", "kind"]) == "not-a-defect"
           end)

    assert second["readiness"] == "not_ready"
  end

  test "a dead holder's audit lock is reclaimed" do
    {root, _package_rel, env} = scheduled_draft!("ready")
    File.mkdir_p!(slug_runtime(root))

    File.write!(
      Path.join(slug_runtime(root), "audit.lock"),
      Jason.encode!(%{"pid" => "2147483000", "started_at" => "Thu Jan  1 00:00:00 1970"})
    )

    assert {:ok, %{"readiness" => "ready"}, _path} = run_audit(root, env)
    refute File.exists?(Path.join(slug_runtime(root), "audit.lock"))
  end

  test "an audit is keyed to the revision it read even when the package is edited mid-audit" do
    {root, package_rel, env} = scheduled_draft!("ready")
    {:ok, before} = Package.load(root, package_rel)
    questions = Path.join([root, package_rel, "questions.md"])
    {:ok, edited?} = Agent.start_link(fn -> false end)

    read = fn path ->
      result = File.read(path)

      if Path.basename(path) == "scenarios.yaml" and
           not Agent.get_and_update(edited?, &{&1, true}) do
        File.write!(questions, "\n2. Edited mid-audit.\n", [:append])
      end

      result
    end

    assert {:ok, report, path} = run_audit(root, env, %{opts: [read: read]})
    assert report["revision"] == before.revision
    assert path == Report.dir(root, "flow-demo", before.revision) <> "/report.json"

    {:ok, after_edit} = Package.load(root, package_rel)
    refute after_edit.revision == before.revision
    assert Report.read(root, "flow-demo", after_edit.revision) == {:error, :missing}
  end

  test "reverting a ready revision cannot reuse its obsolete full report or present it for approval" do
    {root, package_rel, env} = scheduled_draft!("ready")
    intent = Path.join([root, package_rel, "intent.yaml"])
    original = File.read!(intent)
    {:ok, first, path} = run_audit(root, env)

    alias Kogen.Shaping.{Approval, Store}
    dir = Store.session_dir(root, "audit-revert-control")

    session =
      Store.write_session!(dir, %{
        "schema" => Store.schema(),
        "intent_id" => "audit-revert-control",
        "config_fingerprint" => first["config_fingerprint"],
        "route" => first["route"]
      })

    package = %{slug: "flow-demo", package_rel: package_rel}
    assert {:ok, session} = Approval.present!(root, dir, session, package, first, path)

    change_audit_revision!(root, package_rel, "second ready revision")
    assert {:ok, %{"readiness" => "ready"}, _} = run_audit(root, env)
    File.write!(intent, original)
    assert {:ok, %{revision: revision}} = Package.load(root, package_rel)
    assert revision == first["revision"]

    # These are the canonical readers used by status, Stop, runner and approval.
    assert Report.read(root, "flow-demo", revision) == {:error, :missing}
    assert Report.status(root, "flow-demo", revision, first["head"], first["route"]) == :missing
    assert {:stale, _} = Approval.present!(root, dir, session, package, first, path)
    assert {:ok, not_ready, ^path} = run_audit(root, env, %{reuse: true})
    assert not_ready["readiness"] == "not_ready"
    assert not_ready["layers"]["auditor"]["status"] == "missing-confirmation"
    assert auditor_launches(root) == 2
  end

  test "legacy positive reports and auditor records retain counts but require new provenance" do
    {root, package_rel, env} = scheduled_draft!("ready")
    {:ok, first, first_path} = run_audit(root, env)
    change_audit_revision!(root, package_rel, "second ready revision")
    {:ok, second, path} = run_audit(root, env)

    # Schema and contract provenance are separate gates even with a valid
    # current ledger. Preserve a positive control between invalidations.
    current_report = File.read!(path)
    old_report = Jason.decode!(current_report) |> Map.put("schema_version", 2)
    File.write!(path, Jason.encode!(old_report))
    assert Report.read(root, "flow-demo", second["revision"]) == {:error, :missing}
    File.write!(path, current_report)
    assert {:ok, %{"readiness" => "ready"}} = Report.read(root, "flow-demo", second["revision"])

    wrong_contract =
      put_in(
        Jason.decode!(current_report),
        ["layers", "auditor", "contract_version"],
        "old-cross-revision-contract"
      )

    File.write!(path, Jason.encode!(wrong_contract))
    assert Report.read(root, "flow-demo", second["revision"]) == {:error, :missing}
    File.write!(path, current_report)

    ledger = Path.join(slug_runtime(root), "auditor")

    for reservation <- Path.wildcard(Path.join(ledger, "*.json")) do
      legacy = (reservation <> ".completion") |> File.read!() |> Jason.decode!()

      legacy =
        legacy
        |> Map.drop(~w(attempt_id phase contract_version effects))
        |> Map.put("schema_version", 1)

      File.rm!(reservation <> ".completion")
      File.write!(reservation, Jason.encode!(legacy))
    end

    [legacy_path | _] = Path.wildcard(Path.join(ledger, "*.json"))

    uncounted =
      File.read!(legacy_path)
      |> Jason.decode!()
      |> Map.put("counted", false)
      |> Map.put("seq", nil)
      |> Map.put("status", "unavailable")

    uncounted_path = Path.join(ledger, "legacy-uncounted.json")
    uncounted_bytes = Jason.encode!(uncounted)
    File.write!(uncounted_path, uncounted_bytes)

    for report_path <- [first_path, path] do
      old = File.read!(report_path) |> Jason.decode!() |> Map.put("schema_version", 2)
      File.write!(report_path, Jason.encode!(old))
    end

    assert Report.read(root, "flow-demo", first["revision"]) == {:error, :missing}
    assert Report.read(root, "flow-demo", second["revision"]) == {:error, :missing}
    assert {:ok, stale, ^path} = run_audit(root, env, %{reuse: true})
    assert stale["readiness"] == "not_ready"
    assert stale["layers"]["auditor"]["budget_state"]["normal_count"] == 2
    assert auditor_launches(root) == 2
    assert {:ok, confirmed, ^path} = run_audit(root, env, %{confirm?: true, reuse: true})
    assert confirmed["readiness"] == "ready"
    assert confirmed["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    assert {:ok, %{"schema_version" => 3}} = Report.read(root, "flow-demo", second["revision"])
    assert auditor_launches(root) == 3
    assert confirmed["layers"]["auditor"]["budget_state"]["normal_count"] == 2
    assert File.read!(uncounted_path) == uncounted_bytes
    assert length(Path.wildcard(Path.join(ledger, "*.json"))) == 4
  end

  test "malformed, ambiguous and mismatched ledger evidence fails closed without spending fresh allowance" do
    for corruption <- [
          :truncated,
          :array,
          :invalid_sequence,
          :sequence_gap,
          :wrong_completion,
          :duplicate,
          :orphan
        ] do
      {root, _package_rel, env} = scheduled_draft!("ready")
      {:ok, ready, _path} = run_audit(root, env)
      [reservation] = Path.wildcard(Path.join(slug_runtime(root), "auditor/*.json"))
      completion = reservation <> ".completion"

      case corruption do
        :truncated ->
          File.write!(reservation, "{")

        :array ->
          File.write!(reservation, "[]")

        :invalid_sequence ->
          record = File.read!(reservation) |> Jason.decode!() |> Map.put("seq", "one")
          File.write!(reservation, Jason.encode!(record))

        :sequence_gap ->
          for path <- [reservation, completion] do
            record = File.read!(path) |> Jason.decode!() |> Map.put("seq", 2)
            File.write!(path, Jason.encode!(record))
          end

        :wrong_completion ->
          record =
            File.read!(completion) |> Jason.decode!() |> Map.put("revision", "other-revision")

          File.write!(completion, Jason.encode!(record))

        :duplicate ->
          File.cp!(reservation, reservation <> ".copy.json")
          File.cp!(completion, reservation <> ".copy.json.completion")

        :orphan ->
          File.write!(reservation <> ".orphan.completion", "{}")
      end

      ledger_bytes =
        for file <- Path.wildcard(Path.join(slug_runtime(root), "auditor/*")),
            into: %{},
            do: {file, File.read!(file)}

      File.rm_rf!(env["FAKE_AUDITOR_LOG_DIR"])
      assert Report.read(root, "flow-demo", ready["revision"]) == {:error, :missing}

      assert Report.status(root, "flow-demo", ready["revision"], ready["head"], ready["route"]) ==
               :missing

      assert {:ok, unavailable, _} = run_audit(root, env, %{confirm?: true, reuse: true})
      assert unavailable["readiness"] == "not_ready"
      assert unavailable["layers"]["auditor"]["reason"] =~ "ledger integrity"
      refute File.exists?(Path.join(env["FAKE_AUDITOR_LOG_DIR"], "argv"))

      assert ledger_bytes ==
               Map.new(
                 Path.wildcard(Path.join(slug_runtime(root), "auditor/*")),
                 &{&1, File.read!(&1)}
               )
    end
  end
end
