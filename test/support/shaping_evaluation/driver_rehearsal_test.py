#!/usr/bin/env python3
"""Offline rehearsal of the shared engine drive() with a quality-shaped case.

drive() runs against the real `mix kogen.shape` engine (started as a subprocess
in a compiled fixture), the real Stop hook and the real deterministic audit.
Only the provider (test/support/fake_shaping_controller), the Auditor and the
Jev transport are fake. The cases here are engine-step scripts of the same
shape as the quality cases: start, a scripted answer, approve.

Needs the KOGEN_REHEARSAL_ENGINE handoff from mix test (see rehearsal_engine.py);
shaping_evaluation_test.exs runs every method as its own test.
"""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from rehearsal_engine import EngineRehearsal, spawn_violations  # noqa: E402

ANSWER = ("message-1.md", "End the greeting with a period. Record this answer verbatim under Shaper answers and apply it.")


class DriverRehearsalTest(EngineRehearsal):
    def ask_script(self):
        """One turn that drafts and asks one question, then a resumed turn that records
        the answer and stops (the deterministic audit passes the complete package)."""
        return self.script([
            [{"create_draft": {"template": self.template("complete")}},
             {"ask": {"number": 1, "question": "Should the greeting end with a period or an exclamation mark?",
                      "recommendation": "a period", "evidence": "unproven: the Shaper decides"}}],
            [{"record_answers": True}, {"stop": True}]])

    def drive(self, name, steps, *, end, messages=(), max_seconds=120):
        fixture = self.fixture(name, self.brief(name))
        spec = self.case_spec(name, steps, end=end, messages=messages)
        receipt = self.driver.drive(name, fixture, spec, harness="codex", route="codex",
                                    max_seconds=max_seconds, native_binding=False)
        return fixture, receipt

    def test_quality_shaped_case_runs_start_answer_approve_through_engine_commands(self):
        """Correct control: start, one awaiting_answers message, ready, approve; only
        `mix kogen.shape` commands are spawned and config-record.json is written."""
        self.ask_script()
        steps = [{"step": "start", "brief": "brief.md"},
                 {"step": "message", "file": ANSWER[0], "when": "awaiting_answers"},
                 {"step": "approve"}]
        with self.record_spawns():
            _fixture, receipt = self.drive("quality-rehearsal", steps, end="approved", messages=[ANSWER])
        self.assertEqual("completed", receipt["outcome"], receipt["failure"])
        self.assertEqual("approved", receipt["final_state"])
        self.assertEqual([], spawn_violations(self.spawns))
        shape = [argv[argv.index("kogen.shape") + 1:] for argv in self.spawns if "kogen.shape" in argv]
        self.assertIn("--brief", shape[0])
        self.assertTrue(any("--approve" in rest for rest in shape), "the approval used --approve")
        self.assertTrue(any("--brief" in rest and rest[0][0] != "-" for rest in shape),
                        "the answer was sent with --brief to the existing session")
        run = self.driver.RUNTIME / "runs" / "quality-rehearsal"
        record = json.loads((run / "config-record.json").read_text())
        self.assertEqual(["quality-rehearsal", "quality-rehearsal-m1", "quality-rehearsal-approve"],
                         [rid for rid in record["request_ids"] if not rid.endswith("-status")][:3])
        self.assertEqual("codex", record["route"])
        self.assertEqual("codex", record["harness"])
        self.assertTrue(record["kogen_commit"])
        self.assertEqual(1, len(record["provider_session_ids"]))
        self.assertGreaterEqual(len(record["turns"]), 2)
        engine_run = json.loads((run / "engine-run.json").read_text())
        self.assertEqual("approved", engine_run["approval"]["state"])

    def test_wrong_control_missing_scripted_answer_fails_fast(self):
        """Wrong control: the question is never answered because the case has no message.
        drive() fails fast at awaiting_answers instead of waiting out the bound."""
        self.ask_script()
        started = self.driver.monotonic_now()
        _fixture, receipt = self.drive("quality-no-answer", [{"step": "start", "brief": "brief.md"}], end="ready")
        self.assertEqual("TurnEndFailFast", (receipt["failure"] or {}).get("type"), receipt["failure"])
        self.assertIn("awaiting_answers", receipt["failure"]["message"])
        self.assertLess(self.driver.monotonic_now() - started, 100)

    def extra_question_script(self):
        self.script([
            [{"create_draft": {"template": self.template("complete")}},
             {"ask": {"number": 1, "question": "Which first option should the Shaper choose?",
                      "recommendation": "the first option", "evidence": "the Shaper decides"}},
             {"stop": True}],
            [{"record_answers": True},
             {"ask": {"number": 2, "question": "Which second option should the Shaper choose?",
                      "recommendation": "the second option", "evidence": "the Shaper decides"}},
             {"stop": True}],
            [{"record_answers": True}, {"stop": True}],
        ])

    def test_quality_case_accepts_each_explicit_additional_question_round(self):
        """A fixture may need another legitimate answer/turn. Every answer is an
        explicit case file; the driver never manufactures the Shaper's choice."""
        self.extra_question_script()
        messages = [
            ("message-1.md", "Choose the first option."),
            ("message-2.md", "Choose the second option."),
        ]
        steps = [
            {"step": "start", "brief": "brief.md"},
            {"step": "message", "file": "message-1.md", "when": "awaiting_answers"},
            {"step": "message", "file": "message-2.md", "when": "awaiting_answers"},
        ]

        with self.record_spawns():
            _fixture, receipt = self.drive("quality-multi-round", steps, end="ready", messages=messages)

        self.assertEqual("completed", receipt["outcome"], receipt["failure"])
        self.assertEqual("ready", receipt["final_state"])
        self.assertEqual(2, receipt["scripted_replies"])
        self.assertEqual([], spawn_violations(self.spawns))
        run = self.driver.RUNTIME / "runs" / "quality-multi-round"
        engine_run = json.loads((run / "engine-run.json").read_text())
        self.assertEqual(2, len(engine_run["messages"]))
        self.assertEqual([f"{text}\n" for _name, text in messages],
                         [entry["text"] for entry in engine_run["messages"]])
        self.assertGreaterEqual(len(json.loads((run / "config-record.json").read_text())["turns"]), 3)

    def test_wrong_control_extra_question_without_explicit_answer_stays_open(self):
        """An extra Shaper question with no authored answer remains awaiting input;
        the fixture does not mark it resolved or supply a guessed choice."""
        self.extra_question_script()
        messages = [("message-1.md", "Choose the first option.")]
        steps = [
            {"step": "start", "brief": "brief.md"},
            {"step": "message", "file": "message-1.md", "when": "awaiting_answers"},
        ]
        _fixture, receipt = self.drive("quality-missing-extra-answer", steps, end="ready", messages=messages)

        self.assertEqual("TurnEndFailFast", (receipt["failure"] or {}).get("type"), receipt["failure"])
        self.assertIn("awaiting_answers", receipt["failure"]["message"])
        run = self.driver.RUNTIME / "runs" / "quality-missing-extra-answer"
        questions = (run / "draft" / "questions.md").read_text()
        self.assertIn("Which second option should the Shaper choose?", questions)
        self.assertNotIn("Choose the second option.", questions)

    def test_wrong_control_missing_approval_fails_a_case_that_ends_approved(self):
        """Wrong control: a case that must end approved but has no approve step fails
        instead of passing on a merely ready session."""
        self.ask_script()
        steps = [{"step": "start", "brief": "brief.md"},
                 {"step": "message", "file": ANSWER[0], "when": "awaiting_answers"}]
        _fixture, receipt = self.drive("quality-no-approve", steps, end="approved", messages=[ANSWER])
        self.assertEqual("TurnEndFailFast", (receipt["failure"] or {}).get("type"), receipt["failure"])
        self.assertIn("no approve step ran", receipt["failure"]["message"])
        self.assertNotEqual("approved", receipt["final_state"])

    def test_wrong_control_a_non_engine_step_never_reaches_dispatch(self):
        """Wrong control: a continuation-prompt step is rejected before any command runs."""
        fixture = self.fixture("quality-continuation-step", self.brief("x"))
        directory = self.root / "cases" / "bad"
        directory.mkdir(parents=True)
        (directory / "brief.md").write_text(self.brief("x"))
        spec = {"name": "bad", "dir": str(directory), "end": "ready",
                "steps": [{"step": "start", "brief": "brief.md"}, {"step": "continue", "file": "m.md"}]}
        with self.record_spawns():
            with self.assertRaisesRegex(ValueError, "not an engine step"):
                self.driver.drive("bad", fixture, spec, harness="codex", route="codex", native_binding=False)
        self.assertEqual([], [argv for argv in self.spawns if "kogen.shape" in argv])

    def test_wrong_control_expect_spawn_fails_the_rehearsal(self):
        """Wrong control for the spawn rule: an expect transport is a violation."""
        engine = [["mix", "kogen.shape", "--brief", "b.md", "--request-id", "x"],
                  ["mix", "kogen.shape", "0197-x", "--approve", "p-1-abcdef012345"]]
        self.assertEqual([], spawn_violations(engine))
        self.assertTrue(spawn_violations(engine + [["expect", "shape_transport.exp", "/fixture"]]))

    def engine_shaped_suite(self):
        """The suite runtime a live quality run leaves for its final consumers, in the
        engine's shape: integrity.py's own synthetic positive control (native rollouts,
        receipts, public transcripts, fixture facts) with Draft-grade YAML in which
        csv-continuation is one engine session rebound into the frozen seed, as
        driver.rebind_continuation_seed leaves it."""
        integrity = self.driver.integrity_module()
        integrity.make_positive(self.root)
        runtime = self.root / ".kogen/runtime/shaping-evaluation"
        self.driver.PROJECT = self.root
        self.driver.RUNTIME = runtime
        self.driver.write_semantic_counterexamples()
        baseline = {"branch": "main", "head": "abc123"}
        scenarios = ("- id: normalize\n  given: a valid CSV\n  when: normalize INPUT OUTPUT runs\n"
                     "  then: rows are normalized in order\n  wrong_result: the input is mutated\n"
                     "  evidence: a CLI test\n  verified_by: [check]\n")

        def intent(intent_id, slug, started):
            return {"id": intent_id, "slug": slug, "title": slug, "status": "draft", "shaped_against": baseline,
                    "shaping": {"harness": "codex", "model": "gpt-6-astra", "effort": "low", "started": started},
                    "may_change_guarded_paths": ["app/**", "test/**"]}

        for index, case in enumerate(self.driver.CASES):
            run = runtime / "runs" / case
            document = intent(f"01990000-0000-7000-8000-0000000000{index:02d}", f"eval-{case}",
                              f"2026-09-30T00:00:0{index}Z")
            drafts = [run / "draft"] + ([run / "drafts-by-turn" / "0"] if case == "csv-continuation" else [])
            for draft in drafts:
                (draft / "intent.yaml").write_text(json.dumps(document) + "\n")
                (draft / "scenarios.yaml").write_text(scenarios)
            (run / "draft-state.json").write_text(json.dumps({
                "intent_id": document["id"], "baseline": baseline,
                "visit_id": document["shaping"]["started"], "unapproved": True}))
        seed = runtime / "continuation-seed"
        (seed / "frozen-hashes.json").unlink()
        (seed / "intent.yaml").write_text(json.dumps(intent("seed", "eval-csv-seed", "2026-09-01T00:00:00Z")) + "\n")
        (seed / "scenarios.yaml").write_text(scenarios)
        session = json.loads((runtime / "runs/csv-continuation/draft/intent.yaml").read_text())["id"]
        self.driver.rebind_continuation_seed(session)
        return runtime

    def draft_audit(self, runtime):
        code_paths = json.loads(os.environ["KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS"])
        audit = "Code.require_file({}); Kogen.ShapingDraftAudit.audit!({})".format(
            json.dumps(str(HERE / "draft_audit.ex")), json.dumps(str(runtime)))
        result = self.real_run(["elixir", *sum((["-pa", path] for path in code_paths), []), "-e", audit],
                               capture_output=True, text=True, timeout=120)
        return result.returncode, result.stdout + result.stderr

    def test_suite_consumers_accept_one_session_continuation_and_reject_tampering(self):
        """The quality suite's final consumers, unchanged from the live target: the
        driver's own write_manifest() (which runs integrity.validate_manifest) and
        Kogen.ShapingDraftAudit.audit! accept an engine-shaped suite whose
        continuation is one session, and reject a continuation that became a new
        session, altered captured state and a slug changed within the session."""
        runtime = self.engine_shaped_suite()
        locator = self.driver.write_manifest()
        self.assertTrue((self.root / locator["manifest_path"]).is_file())
        status, output = self.draft_audit(runtime)
        self.assertEqual(0, status, output)

        final = runtime / "runs/csv-continuation/draft/intent.yaml"
        state = runtime / "runs/csv-continuation/draft-state.json"
        original_final, original_state = final.read_bytes(), state.read_bytes()
        document = json.loads(original_final)
        document["id"] = "01990000-0000-7000-8000-0000000000ff"
        final.write_text(json.dumps(document) + "\n")
        state.write_text(json.dumps({**json.loads(original_state), "intent_id": document["id"]}))
        with self.assertRaisesRegex(RuntimeError, "continuation lost frozen seed identity"):
            self.driver.write_manifest()
        status, output = self.draft_audit(runtime)
        self.assertNotEqual(0, status)
        self.assertIn("continuation lost the session identity", output)
        final.write_bytes(original_final); state.write_bytes(original_state)

        complete = runtime / "runs/csv-complete/draft-state.json"
        original_complete = complete.read_bytes()
        complete.write_text(json.dumps({**json.loads(original_complete), "visit_id": "altered"}))
        self.driver.write_manifest()
        status, output = self.draft_audit(runtime)
        self.assertNotEqual(0, status)
        self.assertIn("captured state differs", output)
        complete.write_bytes(original_complete)

        partial = runtime / "runs/csv-continuation/drafts-by-turn/0/intent.yaml"
        partial.write_text(json.dumps({**json.loads(partial.read_text()), "slug": "eval-renamed"}) + "\n")
        self.driver.write_manifest()
        status, output = self.draft_audit(runtime)
        self.assertNotEqual(0, status)
        self.assertIn("same-session clarification changed the Draft's slug", output)


if __name__ == "__main__":
    unittest.main()
