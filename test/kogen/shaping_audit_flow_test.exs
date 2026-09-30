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
        "KOGEN_ROLE" => "shaper",
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
end
