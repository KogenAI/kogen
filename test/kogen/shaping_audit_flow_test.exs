Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingAuditFlowTest do
  @moduledoc "Questions and audit state transitions for the Shaping audit."
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingAudit.{Fixture, Package, Questions, Report}

  @fixtures Path.join(File.cwd!(), "test/support/shaping_audit/packages/flow")

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
end
