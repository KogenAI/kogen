Code.require_file("../support/shaping_evaluation/rehearsal_fixture.ex", __DIR__)

defmodule Kogen.ShapingEvaluationTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingEvaluation.RehearsalFixture

  @support Path.expand("../support/shaping_evaluation", __DIR__)
  defp parser_env do
    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.uniq()

    [{"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", Jason.encode!(paths)}]
  end

  test "compact five-case evaluation uses local CLI facts and uses only engine commands" do
    driver = File.read!(Path.join(@support, "driver.py"))
    facts = Jason.decode!(File.read!(Path.join(@support, "compact-fixtures-v2/facts.json")))

    assert driver =~ "MAX_SECONDS = 600"
    assert driver =~ "SUITE_SECONDS = MAX_SECONDS + 120"
    assert driver =~ "deadline = monotonic_now() + SUITE_SECONDS"
    assert driver =~ "setup_continuation_seed()"
    assert driver =~ "KOGEN_SHAPING_EVALUATION_SUITE_BARRIER"
    refute driver =~ ".exp"
    refute driver =~ "transport_test"
    refute driver =~ "managed_resume"
    assert facts["csv"]["feature"] =~ "normalize INPUT OUTPUT"
    assert facts["calendar"]["feature"] =~ "slots CONNECTION"
    refute driver =~ "CSV viewer"
    refute driver =~ "booking service"
  end

  test "compact fixture inputs are local, frozen and source-bound" do
    fixture = Path.join(@support, "compact-fixtures-v2")
    protocol = Jason.decode!(File.read!(Path.join(fixture, "protocol.json")))

    assert protocol["source_hashes"]["facts.json"]

    for name <-
          ~w(facts.json protocol.json reader_control.py calendar_adapter.py capability-seed.json) do
      assert File.regular?(Path.join(fixture, name))
    end
  end

  test "native binding controls reject ambiguous, reused, and interrupted turns" do
    {output, status} =
      System.cmd("python3", ["-B", Path.join(@support, "native_binding_test.py")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "OK"
  end

  test "Check value evidence consumer requires a value and materialized source proof" do
    {output, status} =
      System.cmd("python3", ["-B", Path.join(@support, "value_evidence_test.py")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Ran 1 test"
    assert output =~ "OK"
  end

  test "rollout trigger accepts the string paths returned by session discovery" do
    script = """
    import os, runpy, sys, tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as directory:
        os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = directory
        contains = runpy.run_path(sys.argv[1])["rollout_contains"]
        rollout = Path(directory) / "rollout.jsonl"
        rollout.write_text("Observed UTF-8 BOM discrepancy")
        assert contains(str(rollout), "bom")
        assert contains(rollout, "BOM")
        assert not contains(str(rollout), "invented evidence")
        assert not contains(str(Path(directory) / "missing.jsonl"), "bom")
        print("rollout path controls: ok")
    """

    {output, status} =
      System.cmd("python3", ["-B", "-c", script, Path.join(@support, "driver.py")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "rollout path controls: ok"
  end

  test "Draft provenance projection parses supported YAML forms and rejects partial data" do
    {output, status} =
      System.cmd("python3", ["-B", Path.join(@support, "driver_draft_state_test.py")],
        stderr_to_stdout: true,
        env: parser_env()
      )

    assert status == 0, output
    assert output =~ "OK"
  end

  # The maintained drive() runs against the real engine in a compiled fixture;
  # each Python method is its own test with its own fixture.
  @rehearsal Path.join(@support, "driver_rehearsal_test.py")

  @rehearsal_methods ~r/^    def (test_\w+)\(/m
                     |> Regex.scan(File.read!(@rehearsal), capture: :all_but_first)
                     |> List.flatten()

  test "the rehearsal has the correct control and the wrong controls" do
    assert "test_quality_shaped_case_runs_start_answer_approve_through_engine_commands" in @rehearsal_methods

    assert "test_quality_case_accepts_each_explicit_additional_question_round" in @rehearsal_methods

    assert "test_wrong_control_extra_question_without_explicit_answer_stays_open" in @rehearsal_methods

    assert "test_wrong_control_missing_scripted_answer_fails_fast" in @rehearsal_methods

    assert "test_wrong_control_missing_approval_fails_a_case_that_ends_approved" in @rehearsal_methods

    assert "test_wrong_control_expect_spawn_fails_the_rehearsal" in @rehearsal_methods
    assert length(@rehearsal_methods) == length(Enum.uniq(@rehearsal_methods))
  end

  for method <- @rehearsal_methods do
    @tag timeout: 600_000
    test "offline rehearsal #{method}" do
      fixture = RehearsalFixture.create!()
      on_exit(fn -> RehearsalFixture.cleanup!(fixture) end)
      {_root, handoff} = fixture

      {output, status} =
        System.cmd(
          "python3",
          ["-B", @rehearsal, "DriverRehearsalTest.#{unquote(method)}"],
          stderr_to_stdout: true,
          env: [
            {"KOGEN_ROLE", nil},
            {"KOGEN_HARNESS_HOME", nil},
            {RehearsalFixture.handoff_env(), handoff}
            | parser_env()
          ]
        )

      assert status == 0, output
      assert output =~ "Ran 1 test"
      assert output =~ "OK"
      refute output =~ "skipped", "the rehearsal must not skip: #{output}"
    end
  end

  defp run_driver_python!(script, args) do
    {output, status} =
      System.cmd("python3", ["-B", "-c", script, Path.join(@support, "driver.py") | args],
        stderr_to_stdout: true,
        env: [
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", System.tmp_dir!()},
          {"KOGEN_HARNESS", "offline-fake"}
        ]
      )

    {status, output}
  end

  @load_cases """
  import runpy, sys
  driver = runpy.run_path(sys.argv[1])
  names = driver["case_names"]()
  assert names, "no cases"
  for name in names:
      spec = driver["load_case"](name)
      assert [s["step"] for s in spec["steps"]][0] == "start"
  print("cases ok: " + ",".join(names))
  """

  test "every quality case is a list of engine steps only" do
    dirs = Path.wildcard(Path.join(@support, "cases/*/case.json"))
    assert length(dirs) >= 8

    for path <- dirs do
      steps = path |> File.read!() |> Jason.decode!() |> Map.fetch!("steps")
      assert Enum.all?(steps, &(&1["step"] in ~w(start message approve cancel))), path
    end

    {status, output} = run_driver_python!(@load_cases, [])
    assert status == 0, output
    assert output =~ "cases ok:"
    assert output =~ "headless-flow"
  end

  @reject_case """
  import json, runpy, sys, tempfile
  from pathlib import Path
  driver = runpy.run_path(sys.argv[1])
  bad_steps = {
      "continuation": [{"step": "start", "brief": "brief.md"}, {"step": "continuation", "file": "m.md"}],
      "continue": [{"step": "start", "brief": "brief.md"}, {"step": "continue", "file": "m.md"}],
      "resume-prompt": [{"step": "start", "brief": "brief.md"}, {"step": "resume", "file": "m.md"}],
  }
  with tempfile.TemporaryDirectory() as directory:
      for name, steps in bad_steps.items():
          case = Path(directory) / name
          case.mkdir()
          (case / "case.json").write_text(json.dumps({"name": name, "steps": steps}))
          try:
              driver["load_case"](name, directory)
          except ValueError as exc:
              assert "not an engine step" in str(exc), exc
          else:
              raise SystemExit(f"{name} was accepted")
      good = Path(directory) / "good"
      good.mkdir()
      (good / "case.json").write_text(json.dumps({"name": "good", "steps": [
          {"step": "start", "brief": "brief.md"}, {"step": "message", "file": "m.md"}, {"step": "approve"}]}))
      driver["load_case"]("good", directory)
  print("wrong controls rejected")
  """

  test "the driver's own case validation rejects a continuation-prompt step" do
    {status, output} = run_driver_python!(@reject_case, [])
    assert status == 0, output
    assert output =~ "wrong controls rejected"
  end

  test "the headless-flow case keeps its brief and scripted messages" do
    dir = Path.join(@support, "cases/headless-flow")
    spec = dir |> Path.join("case.json") |> File.read!() |> Jason.decode!()

    assert [%{"step" => "start", "brief" => "brief.md"} | messages] = spec["steps"]
    assert length(messages) >= 2
    assert Enum.all?(messages, &(&1["step"] == "message"))
    assert hd(messages)["when"] == "mid_turn"
    assert Enum.any?(tl(messages), &(&1["when"] in ["awaiting_answers", "turn_ended"]))

    for file <- ["brief.md", "message-1.md", "message-2.md"] do
      assert File.read!(Path.join(dir, file)) |> String.trim() != ""
    end

    assert File.read!(Path.join(dir, "message-2.md")) =~ "not another decision"
  end

  @config_record """
  import json, runpy, sys, tempfile
  from pathlib import Path
  from types import SimpleNamespace
  driver = runpy.run_path(sys.argv[1])
  session = SimpleNamespace(request_ids=["r-start", "r-approve"], session="sess-1", commands=[{"argv": ["mix"]}])
  events = [
      {"at": "t1", "event": "turn_started", "turn": 1, "kind": "fresh", "provider_session_id": "prov-1", "route": "optimum"},
      {"at": "t2", "event": "turn_ended", "turn": 1, "exit": 0, "usage": {"input_tokens": 3}},
  ]
  with tempfile.TemporaryDirectory() as directory:
      out = Path(directory)
      driver["write_config_record"](out, case="headless-flow", harness="codex", route="optimum",
          profiles={"root": ("gpt-6-astra", "low")}, session=session, events=events,
          started="s", ended="e", fixture_root=out)
      print(json.dumps(json.loads((out / "config-record.json").read_text())))
  """

  test "the driver writes config-record.json with the run's provenance" do
    {status, output} = run_driver_python!(@config_record, [])
    assert status == 0, output
    record = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert record["route"] == "optimum"
    assert record["harness"] == "codex"
    assert record["model"] == "gpt-6-astra"
    assert record["effort"] == "low"
    assert Map.has_key?(record, "kogen_commit")
    assert Map.has_key?(record, "harness_version")
    assert record["request_ids"] == ["r-start", "r-approve"]
    assert record["started_at"] == "s" and record["ended_at"] == "e"
    assert record["provider_session_ids"] == ["prov-1"]
    assert Path.type(record["shaping_root"]) == :absolute
    assert record["shaping_intent_id"] == "sess-1"

    assert [turn] = record["turns"]
    assert turn["usage"] == %{"input_tokens" => 3}
    assert turn["provider_session_id"] == "prov-1"
    assert turn["first_at"] == "t1" and turn["last_at"] == "t2"

    # drive() must call it for every run.
    assert File.read!(Path.join(@support, "driver.py")) =~ ~s|capture("config-record"|
  end

  # A driver spawns providers only through `mix kogen.shape`; any expect/pty
  # transport is a violation. Comments and docstrings are not spawns.
  defp native_transport_uses(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.filter(
      &Regex.match?(~r/"expect"|\bpexpect\b|\bforkpty\b|\bopenpty\b|\bpty\.spawn\b|\.exp\b/, &1)
    )
  end

  test "the driver spawns only mix kogen.shape and never expect, with a wrong control" do
    driver = File.read!(Path.join(@support, "driver.py"))
    assert native_transport_uses(driver) == []
    assert driver =~ ~s|[*MIX_COMMAND, "kogen.shape"|

    for flag <- ~w(--brief --approve --cancel), do: assert(driver =~ ~s|"#{flag}"|)

    wrong = ~s|subprocess.run(["expect", "-f", "shape_transport.exp"], cwd=fixture)|
    assert native_transport_uses(wrong) != []
  end
end
