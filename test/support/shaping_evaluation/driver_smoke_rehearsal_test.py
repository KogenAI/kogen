#!/usr/bin/env python3
"""Offline rehearsal for the headless-flow smoke case (driver.py --smoke).

The real driver.run_smoke() -> setup_fixture() -> drive() path runs against the
real `mix kogen.shape` engine (started by the driver as a subprocess in a
compiled fixture), the real Stop hook and the real deterministic audit. Only the
provider is fake: test/support/fake_shaping_controller, scripted per test. The
Auditor and Jev transports are fakes as well. Mix compile and the fixture
validator are the only stubbed boundaries, as in the earlier rehearsals.

Needs the KOGEN_REHEARSAL_ENGINE handoff from mix test (see
rehearsal_engine.py); shaping_smoke_rehearsal_test.exs runs every method.
"""
import contextlib
import base64
import difflib
import datetime
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from rehearsal_engine import EngineRehearsal, spawn_violations  # noqa: E402


def stub_mix_compile(real_run):
    """`mix compile` is the one boundary stubbed: the compiled fixture already loads
    this build's BEAM files."""
    class Done:
        returncode = 0; stdout = ""; stderr = ""

    def run(argv, *args, **kwargs):
        if list(argv[:2]) == ["mix", "compile"]:
            return Done()
        return real_run(argv, *args, **kwargs)
    return run


class DriverSmokeRehearsalTest(EngineRehearsal):
    def setUp(self):
        super().setUp()
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        # The fixture source (PROJECT) is the compiled engine fixture; the real
        # setup_fixture() copies it, adds the smoke evidence and commits a baseline.
        self.project = self.root / "project"
        shutil.copytree(self.info["fixture"], self.project, symlinks=True)
        self.runtime_dir = self.project / ".kogen" / "runtime" / "smoke-rehearsal"
        self.runtime_dir.mkdir(parents=True)
        self.driver.PROJECT = self.project
        self.driver.RUNTIME = self.runtime_dir.resolve()
        # As in a live run: integrity.py loads its own driver copy (YAML parser)
        # and that copy reads the evaluation runtime from the environment.
        runtime_env = patch.dict(os.environ, {"KOGEN_SHAPING_EVALUATION_RUNTIME": str(self.driver.RUNTIME)})
        runtime_env.start()
        self.addCleanup(runtime_env.stop)
        self.driver.SESSION_ROOT = self.root / "sessions"
        self.validated = []
        def recorded_validation(fixture, label, extra_files, draft=None):
            self.validated.append(label)
            return {"label": label, "digest": "0" * 64, "providers_denied": False, "files": 1}
        self.driver.validate_generated_fixture = recorded_validation
        self.head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.info["fixture"], capture_output=True,
                                   text=True, check=True).stdout.strip()

    def rehomed_template(self, name, head):
        """A template package whose baseline is the smoke fixture's own HEAD."""
        target = self.root / f"template-{name}"
        shutil.copytree(self.template(name), target)
        intent = target / "intent.yaml"
        intent.write_text(intent.read_text().replace(self.head, head))
        return target

    def headless_script(self, head, *, audited=True, steer=True, record_in_turn=True,
                        repair_independently=False, message_count=2, record_last_message=True):
        """Turn 1 asks the one question, keeps working while the answer arrives as a
        steer, then stops: the Stop hook blocks the flawed first Draft and the same
        provider session repairs it. The suppression control can repair after the
        Stop step independently. Turn 2 answers the follow-up on resume."""
        flawed = self.rehomed_template("flawed", head)
        complete = self.rehomed_template("complete", head)
        repaired = (complete / "scenarios.yaml").read_text()
        keep_working = []
        for _ in range(5 if steer and record_in_turn else 3):
            keep_working += [{"sleep": 3}] + ([{"hook": "post_tool_use"}] if steer else [])
        # `steer=False` is the steering-disabled control (no PostToolUse delivery);
        # `record_in_turn=False` delivers the answer but the original turn never records it.
        record = [{"record_answers": True}] if record_in_turn else []
        stop = {"stop": True, "on_block": [
            {"write": {"path": ".kogen/intents/drafts/complete/scenarios.yaml", "text": repaired}}, *record]}
        first = [{"create_draft": {"template": str(flawed)}},
                 {"ask": {"number": 1, "question": "Should the greeting end with a period or an exclamation mark?",
                          "recommendation": "a period", "evidence": "unproven: the Shaper decides"}},
                 *keep_working, *record]
        if repair_independently:
            # Once the answer is recorded, await the production runner's
            # checkpoint notice before ending this turn. The real hook must
            # offer it even though the relay suppresses its output. This
            # barrier works under suite load without assuming a fixed sleep
            # is long enough for an asynchronous audit to complete.
            first += [{"wait_for": {"path": ".kogen/runtime/shaping/*/notices/au-*.json",
                                    "timeout": 60}},
                      {"hook": "post_tool_use"}]
        first.append(stop if audited else {"record_answers": True})
        if repair_independently:
            # This control models an independent Shaper edit after the audit
            # producer has run. It must still repair and reach ready when the
            # host-facing output relay suppresses every feedback byte.
            first += [{"write": {"path": ".kogen/intents/drafts/complete/scenarios.yaml", "text": repaired}},
                      {"stop": True}]
        turns = [first, [{"record_answers": True}, {"stop": True}]]
        for index in range(2, message_count):
            final = [{"record_answers": True}] if record_last_message else []
            turns.append([*final, {"stop": True}])
        return self.script(turns)

    def run_smoke(self, harness="codex", *, audited=True, message_count=2,
                  record_last_message=True, case_spec=None, **script):
        """The real run_smoke(); only `mix compile` is stubbed, and the fake provider
        script is built from the smoke fixture's own HEAD right before the launch."""
        real_run = self.driver.subprocess.run
        real_drive = self.driver.drive

        def drive(case, fixture, spec, **kwargs):
            head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=fixture, capture_output=True,
                                  text=True, check=True).stdout.strip()
            self.headless_script(head, audited=audited, message_count=message_count,
                                 record_last_message=record_last_message, **script)
            return real_drive(case, fixture, spec, **kwargs)

        case_loader = (patch.object(self.driver, "load_case", lambda _name: case_spec)
                       if case_spec is not None else contextlib.nullcontext())
        with patch.object(self.driver.subprocess, "run", stub_mix_compile(real_run)), \
             patch.object(self.driver, "drive", drive), case_loader:
            return self.driver.run_smoke(harness)

    def three_message_smoke_case(self):
        source = Path(self.driver.CASES_DIR) / "headless-flow"
        case_dir = self.root / "headless-flow-three-message"
        shutil.copytree(source, case_dir)
        (case_dir / "message-3.md").write_text(
            "Please finish using the period I already chose; no further product decision is needed.\n"
        )
        spec = json.loads((case_dir / "case.json").read_text())
        spec["steps"].append({"step": "message", "file": "message-3.md", "when": "turn_ended"})
        spec["note"] = "Offline smoke-path control with three explicit messages; the extra follow-up repeats the settled choice."
        (case_dir / "case.json").write_text(json.dumps(spec, indent=2) + "\n")
        spec["name"] = "headless-flow"
        spec["dir"] = str(case_dir)
        return self.driver.validate_case_spec(spec)

    def frames(self):
        return [line for line in self.output.getvalue().splitlines()
                if line.startswith("KOGEN_TARGET_EVIDENCE_MANIFEST\t")]

    def test_smoke_bounds_case_files_and_briefs_are_consistent(self):
        self.assertEqual(self.driver.SMOKE_MAX_SECONDS, 20 * 60)
        self.assertEqual(self.driver.ROUTE_READY_SECONDS, 20 * 60)
        self.assertEqual(self.driver.SMOKE_SUITE_SECONDS, 45 * 60)
        spec = self.driver.load_case("headless-flow")
        self.assertEqual(["start", "message", "message"], [step["step"] for step in spec["steps"]])
        self.assertEqual(["mid_turn", "turn_ended"], [step["when"] for step in spec["steps"][1:]])
        self.assertEqual("ready", spec["end"])
        brief = (Path(spec["dir"]) / "brief.md").read_text()
        self.assertEqual(self.driver.SMOKE_REQUEST, brief)
        self.assertEqual(1, len([p for p in brief.split("\n\n") if p.strip()]), "the brief is one paragraph")
        self.assertEqual([self.driver.SMOKE_ANSWER, self.driver.SMOKE_FOLLOWUP],
                         [text.strip() for text in self.driver.case_messages(spec)])
        self.assertEqual(self.driver.current_request("smoke"), self.driver.SMOKE_REQUEST)

    def test_rehearsal_fixture_runs_real_audit_and_verification_plan_on_repaired_drafts(self):
        audit = self.info.get("fixture_audit")
        self.assertIsInstance(audit, dict)
        self.assertEqual(
            "Kogen.ShapingAudit.Deterministic + Kogen.Build.VerificationPlan",
            audit["consumer"],
        )
        for name in ("smoke", "shape_to_build"):
            self.assertEqual("ok", audit[name]["readiness"], name)
            self.assertEqual([], audit[name]["proof_errors"], name)
            self.assertEqual([], audit[name]["blocking_findings"], name)
        self.assertTrue(any(item[0] == "proof-selector-missing"
                            for item in audit["unsupported_selector_control"]))
        self.assertIn(["unguarded-affected-path", "Makefile"], audit["unguarded_makefile_control"])
        contract = audit["smoke"]["contract"]
        self.assertEqual([], contract["errors"])
        self.assertEqual(
            {"absent-producer", "literal-only-test", "missing-cited-facts", "contradictory-scope"},
            {control["name"] for control in contract["negative_controls"] if control["rejected"]},
        )

    def test_smoke_greeting_proof_reads_the_actual_future_artifact(self):
        fixture = self.driver.setup_fixture("smoke", self.driver.smoke_files(),
                                            name="greeting-proof-control", bootstrap=False)
        copied = fixture / "test/fixture_greeting_contract_test.exs"
        self.assertEqual(self.driver.SMOKE_GREETING_PROOF, copied.read_text())
        self.assertIn("mix test test/fixture_greeting_contract_test.exs", (fixture / "Makefile").read_text())
        self.assertIn("Kogen.GreetingWriter.write!", copied.read_text())
        self.assertIn("Code.require_file(\"../app/greeting_writer.ex\"", copied.read_text())
        argv = self.driver.eval_argv("ExUnit.start(); Code.compile_file(hd(System.argv()))")
        argv += ["--", str(copied)]

        def check():
            return subprocess.run(argv, cwd=fixture, capture_output=True, text=True,
                                  env=self.driver.external_driver_env(fixture, self.driver.ENGINE_ENV),
                                  timeout=60)

        correct = check()
        self.assertEqual(0, correct.returncode, correct.stdout + correct.stderr)
        self.assertIn("Result: 1 passed", correct.stdout + correct.stderr)

        producer = fixture / "app/greeting_writer.ex"
        original = producer.read_text()
        producer.write_text(original.replace(
            '["Hello", punctuation, "\\n"]', '["Hello", "!", "\\n"]'))
        wrong = check()
        self.assertNotEqual(0, wrong.returncode, wrong.stdout + wrong.stderr)
        self.assertIn("Assertion with == failed", wrong.stdout + wrong.stderr)
        self.assertIn("Hello!", wrong.stdout + wrong.stderr)

    def test_runtime_absent_prepare_succeeds_but_ordinary_execution_refuses(self):
        """Standalone setup owns and removes a private runtime; live execution
        still requires the caller-owned runtime. Login/toolchain are synthetic,
        and the subprocess has no provider dispatch configuration."""
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("KOGEN_") and key != "MIX_BUILD_PATH"}
        env.update({
            "KOGEN_PREPARE_FORCE_SCOPE": "pass",
            "KOGEN_PREPARE_FORCE_TOOLCHAIN": "pass",
            "KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS": os.environ[
                "KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS"],
        })
        # Scrub runtime/role selectors, while preserving the controller's
        # provider-denial boundary and resolved Git required by its PATH shim.
        # Both prepares own independent runtimes
        # and must settle before this fixture and its parser paths disappear.
        for key in ("KOGEN_PROVIDERS_DENIED", "KOGEN_CHECK_GIT"):
            if key in os.environ:
                env[key] = os.environ[key]
        if "KOGEN_CHECK_GIT" in env:
            # Observe the gate's exact failure without invoking a gate: the
            # wrapper refuses a scrubbed binding, then accepts the preserved one.
            git_shim = HERE.parents[2] / "scripts" / "check" / "bin" / "git"
            unbound = dict(env)
            del unbound["KOGEN_CHECK_GIT"]
            refused = subprocess.run([str(git_shim), "--version"], env=unbound,
                                     capture_output=True, text=True, timeout=30)
            self.assertNotEqual(0, refused.returncode)
            self.assertIn("offline recipe did not resolve Git", refused.stderr)
            resolved = subprocess.run([str(git_shim), "--version"], env=env,
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(0, resolved.returncode, resolved.stdout + resolved.stderr)
        self.assertNotIn("KOGEN_SHAPING_EVALUATION_RUNTIME", env)
        def prepare_without_runtime():
            return subprocess.run(["python3", "-B", str(HERE / "driver.py"), "--prepare", "smoke"],
                                  cwd=self.project, env=env, capture_output=True, text=True, timeout=240)
        with ThreadPoolExecutor(max_workers=2) as pool:
            prepares = list(pool.map(lambda _: prepare_without_runtime(), range(2)))
        for prepare in prepares:
            self.assertEqual(0, prepare.returncode, prepare.stdout + prepare.stderr)
        self.assertNotIn("KOGEN_SHAPING_EVALUATION_RUNTIME", env)
        ordinary = subprocess.run(["python3", "-B", str(HERE / "driver.py"), "--smoke"],
                                  cwd=self.project, env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, ordinary.returncode)
        self.assertIn("KOGEN_SHAPING_EVALUATION_RUNTIME", ordinary.stderr)

    def test_parser_dependency_and_lifetime_controls_have_no_provider_dispatch(self):
        """The same parser subprocess accepts and rejects YAML, settles before
        fixture teardown, and invokes only the bare Elixir parser boundary."""
        code_paths = json.loads(os.environ["KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS"])
        yamerl = [path for path in code_paths if Path(path).name == "ebin" and "yamerl" in path]
        self.assertTrue(yamerl, f"compiled yamerl ebin absent from current paths: {code_paths}")
        with self.record_spawns():
            self.assertEqual({"answer": 42}, self.driver.parse_yaml_document(
                b"answer: 42\n", case="parser control", source="valid-control"))
            with self.assertRaisesRegex(self.driver.DraftParseError, "malformed YAML"):
                self.driver.parse_yaml_document(b"answer: [\n", case="parser control", source="invalid-control")
        self.assertEqual([], [argv for argv in self.spawns if "kogen.shape" in argv],
                         "parser controls must not dispatch an engine/provider")

    def test_smoke_rehearsal_dispatches_real_functions_and_manifests_once(self):
        """Correct control: the real run_smoke() drives one codex-route session through
        start, a mid-turn answer, audit feedback, a resumed message and ready."""
        trace = self.root / "trace.txt"
        external_fixtures = self.root / "fixtures-outside-project"
        with patch.dict(os.environ, {"KOGEN_REHEARSAL_TRACE": str(trace),
                                     self.driver.FIXTURE_ROOT_ENV: str(external_fixtures)}), self.record_spawns():
            status = self.run_smoke("codex")
        stdout = self.output.getvalue()
        self.assertEqual(0, status, stdout)
        self.assertNotIn("TurnEndFailFast", stdout)
        self.assertEqual([], spawn_violations(self.spawns))
        shape_spawns = [argv for argv in self.spawns if "kogen.shape" in argv]
        self.assertTrue(shape_spawns)
        first = shape_spawns[0][shape_spawns[0].index("kogen.shape") + 1:]
        self.assertEqual(["--brief"], [part for part in first if part.startswith("--brief")])
        self.assertIn("--request-id", first); self.assertEqual("smoke", first[first.index("--request-id") + 1])
        self.assertTrue(any("--approve" not in argv and "--brief" in argv and argv[argv.index("kogen.shape") + 1][0] != "-"
                            for argv in shape_spawns), "a message was sent with --brief to an existing session")
        self.assertEqual(1, len(self.frames()), "the manifest frame must be printed exactly once")
        locator = json.loads(self.frames()[0].split("\t", 1)[1])
        manifest = self.project / locator["manifest_path"]
        self.assertTrue(manifest.is_file())
        self.assertFalse((self.driver.RUNTIME / "smoke").exists(), "the fixture is cleaned on a clean exit")
        lines = trace.read_text().splitlines() if trace.is_file() else []
        self.assertIn("driver.run_smoke", lines)
        self.assertIn("driver.setup_fixture", lines)
        self.assertIn("Kogen.ShapingEvaluation.Integrity.validate_smoke_manifest", lines)
        run = self.driver.RUNTIME / "runs" / "smoke"
        receipt = json.loads((run / "receipt.json").read_text())
        self.assertFalse(Path(receipt["fixture"]).resolve().is_relative_to(self.project.resolve()),
                         "the live fixture must be outside the publishable project")
        self.assertFalse(Path(receipt["fixture"]).exists(), "a successful smoke cleans the external fixture")
        self.assertTrue(external_fixtures.is_dir())
        self.assertEqual([], list(external_fixtures.iterdir()))
        result = json.loads((run / "smoke-result.json").read_text())
        self.assertEqual([], result["failures"], result)
        record = json.loads((run / "config-record.json").read_text())
        self.assertEqual("codex", record["harness"])
        self.assertEqual("codex", record["route"])
        self.assertTrue(record["model"])
        self.assertEqual("low", record["effort"])
        self.assertEqual(["smoke", *[f"smoke-m{index + 1}" for index, _ in enumerate(self.driver.case_messages(
            self.driver.load_case("headless-flow")))]],
            [i for i in record["request_ids"] if not i.endswith("-status")])
        self.assertTrue(record["kogen_commit"])
        self.assertIn("binary", record["harness_version"])
        self.assertGreaterEqual(len(record["turns"]), 2)
        self.assertEqual(1, len(record["provider_session_ids"]))
        self.assertTrue(all(turn["provider_session_id"] == record["provider_session_ids"][0] for turn in record["turns"]))
        self.assertTrue(all(turn["usage"] for turn in record["turns"]), record["turns"])
        self.assertLess(record["started_at"], record["ended_at"])

        # Wrong controls for the independent consumer: integrity.py re-derives the
        # outcome from the engine's evidence, so a presented report that is not ready
        # or a config record naming another provider session is refused and leaves
        # no manifest behind.
        for name, tamper in (("presented-report.json", lambda data: {**data, "readiness": "not_ready"}),
                             ("config-record.json", lambda data: {**data, "provider_session_ids": ["other"]})):
            path = run / name
            original = path.read_bytes()
            path.write_text(json.dumps(tamper(json.loads(original))))
            with self.assertRaisesRegex(RuntimeError, "smoke manifest integrity validation failed"):
                self.driver.write_smoke_manifest()
            self.assertFalse((self.driver.RUNTIME / "evidence-manifest.json").exists())
            path.write_bytes(original)
        self.driver.write_smoke_manifest()

    def test_smoke_rehearsal_claude_route_uses_the_same_flow(self):
        with self.record_spawns():
            status = self.run_smoke("claude")
        self.assertEqual(0, status, self.output.getvalue())
        record = json.loads((self.driver.RUNTIME / "runs" / "smoke" / "config-record.json").read_text())
        self.assertEqual("claude", record["harness"])
        self.assertEqual("claude", record["route"])
        self.assertEqual([], spawn_violations(self.spawns))

    def test_smoke_setup_copy_exception_cleans_only_the_owned_partial_fixture(self):
        """Fault control: a setup failure leaves a cause and cleanup receipt in
        retained runtime evidence, then removes only the smoke tree this run claimed."""
        external = self.root / "owned-fixtures"
        fixture = external / "smoke"
        real_rmtree = self.driver.shutil.rmtree

        def check_cleanup_receipt_precedes_delete(path, *args, **kwargs):
            if Path(path) == fixture:
                cleanup = json.loads((self.driver.RUNTIME / "runs/smoke/fixture-cleanup.json").read_text())
                self.assertTrue(cleanup["removal_pending"], cleanup)
                self.assertTrue(cleanup["owned_processes"]["all_reaped"], cleanup)
                self.assertIn("planted copy fault", cleanup["failure"]["message"])
            return real_rmtree(path, *args, **kwargs)

        with patch.dict(os.environ, {self.driver.FIXTURE_ROOT_ENV: str(external)}), \
             patch.object(self.driver, "copy_fixture_source_tree", side_effect=OSError("planted copy fault")), \
             patch.object(self.driver.shutil, "rmtree", side_effect=check_cleanup_receipt_precedes_delete):
            with self.assertRaisesRegex(OSError, "planted copy fault"):
                self.driver.run_smoke("codex")

        self.assertFalse(fixture.exists())
        self.assertTrue(external.is_dir())
        self.assertEqual([], list(external.iterdir()))
        run = self.driver.RUNTIME / "runs" / "smoke"
        failure = json.loads((run / "driver-failure.json").read_text())
        self.assertEqual("fixture-setup", failure["stage"])
        self.assertEqual("OSError", failure["type"])
        self.assertIn("planted copy fault", failure["message"])
        cleanup = json.loads((run / "fixture-cleanup.json").read_text())
        self.assertTrue(cleanup["removed"], cleanup)
        self.assertTrue(cleanup["owned_processes"]["all_reaped"], cleanup)
        self.assertEqual(failure, cleanup["failure"])

    def test_smoke_early_drive_exception_cleans_only_the_owned_fixture_after_settlement(self):
        """A driver-entry failure has no completed run receipt, but its cause and
        owned-process settlement must be retained before deleting the owned fixture."""
        external = self.root / "owned-drive-fixtures"
        fixture = external / "smoke"
        real_rmtree = self.driver.shutil.rmtree
        real_run = self.driver.subprocess.run

        def check_cleanup_receipt_precedes_delete(path, *args, **kwargs):
            if Path(path) == fixture:
                cleanup = json.loads((self.driver.RUNTIME / "runs/smoke/fixture-cleanup.json").read_text())
                self.assertTrue(cleanup["removal_pending"], cleanup)
                self.assertTrue(cleanup["owned_processes"]["all_reaped"], cleanup)
                self.assertIn("planted early drive fault", cleanup["failure"]["message"])
            return real_rmtree(path, *args, **kwargs)

        with patch.dict(os.environ, {self.driver.FIXTURE_ROOT_ENV: str(external)}), \
             patch.object(self.driver.subprocess, "run", stub_mix_compile(real_run)), \
             patch.object(self.driver, "drive", side_effect=RuntimeError("planted early drive fault")), \
             patch.object(self.driver.shutil, "rmtree", side_effect=check_cleanup_receipt_precedes_delete):
            with self.assertRaisesRegex(RuntimeError, "planted early drive fault"):
                self.driver.run_smoke("codex")

        self.assertFalse(fixture.exists())
        self.assertTrue(external.is_dir())
        self.assertEqual([], list(external.iterdir()))
        run = self.driver.RUNTIME / "runs" / "smoke"
        failure = json.loads((run / "driver-failure.json").read_text())
        self.assertEqual("drive", failure["stage"])
        self.assertEqual("RuntimeError", failure["type"])
        self.assertIn("planted early drive fault", failure["message"])
        cleanup = json.loads((run / "fixture-cleanup.json").read_text())
        self.assertTrue(cleanup["removed"], cleanup)
        self.assertTrue(cleanup["owned_processes"]["all_reaped"], cleanup)
        self.assertEqual(failure, cleanup["failure"])

    def test_smoke_preserves_a_preexisting_external_fixture_root(self):
        """A path not claimed by this run remains intact, including its contents."""
        external = self.root / "preexisting-fixtures"
        fixture = external / "smoke"
        fixture.mkdir(parents=True)
        marker = fixture / "owner-marker.txt"
        marker.write_text("owned by another run\n")

        with patch.dict(os.environ, {self.driver.FIXTURE_ROOT_ENV: str(external)}):
            with self.assertRaisesRegex(RuntimeError, "fixture exists"):
                self.driver.run_smoke("codex")

        self.assertEqual("owned by another run\n", marker.read_text())
        self.assertEqual([marker], list(fixture.iterdir()))
        run = self.driver.RUNTIME / "runs" / "smoke"
        failure = json.loads((run / "driver-failure.json").read_text())
        self.assertEqual("fixture-location", failure["stage"])
        self.assertIn("fixture exists", failure["message"])
        self.assertFalse((run / "fixture-cleanup.json").exists())

    def test_smoke_path_accepts_three_authored_messages_and_binds_each(self):
        """Positive control: run_smoke and its independent consumer accept a third
        explicit follow-up because its text, delivery, request ID and answer record
        are all bound to the authored case snapshot."""
        spec = self.three_message_smoke_case()
        with self.record_spawns():
            status = self.run_smoke("codex", message_count=3, case_spec=spec)
        self.assertEqual(0, status, self.output.getvalue())
        run = self.driver.RUNTIME / "runs" / "smoke"
        result = json.loads((run / "smoke-result.json").read_text())
        self.assertTrue(result["checks"]["all-explicit-messages-sent"]["ok"])
        self.assertTrue(result["checks"]["two-messages-sent"]["ok"])
        sent = json.loads((run / "messages.json").read_text())
        self.assertEqual(3, len(sent))
        self.assertEqual(["smoke", "smoke-m1", "smoke-m2", "smoke-m3"],
                         json.loads((run / "config-record.json").read_text())["request_ids"])
        authored = json.loads((run / "authored-case.json").read_text())
        self.assertEqual(3, len(authored["messages"]))
        self.driver.integrity_module().validate_smoke_case(self.driver.RUNTIME)

    def test_smoke_path_three_message_wrong_control_requires_each_answer_record(self):
        """Negative control: a delivered third message that the Shaper never records
        cannot pass just because the session still reaches ready."""
        spec = self.three_message_smoke_case()
        with self.record_spawns():
            status = self.run_smoke("codex", message_count=3, record_last_message=False, case_spec=spec)
        self.assertEqual(1, status, self.output.getvalue())
        self.assertEqual(0, len(self.frames()))
        run = self.driver.RUNTIME / "runs" / "smoke"
        result = json.loads((run / "smoke-result.json").read_text())
        self.assertTrue(result["checks"]["two-messages-sent"]["ok"])
        self.assertFalse(result["checks"]["answers-recorded-verbatim-with-input-tokens"]["ok"])
        self.assertEqual(3, len(json.loads((run / "messages.json").read_text())))
        self.assertFalse((self.driver.RUNTIME / "evidence-manifest.json").exists())

    def feedback_identity_case(self, name, *, route, harness, boundary,
                               provider=None, receipt_route=None):
        run = self.root / name
        target, final, launch = "a" * 64, "f" * 64, "root-launch"
        intent_id = "feedback-identity"
        session = self.root / "canonical-root/.kogen/runtime/shaping" / intent_id
        report = run / "shaping-audits" / "fixture"
        report.mkdir(parents=True)
        (report / "report.json").write_text(json.dumps({
            "revision": target,
            "findings": [{"id": "audit-block", "severity": "blocking", "still_open": True}],
        }))
        (run / "config-record.json").write_text(json.dumps({
            "route": route, "harness": harness, "shaping_root": str(session.parents[3]),
            "shaping_intent_id": intent_id,
        }))
        (run / "shaping-audits/hook.jsonl").write_text(json.dumps({
            "revision": target, "decision": "block", "blocking": ["audit-block"],
            "at": "2026-01-01T00:00:02+00:00",
        }) + "\n")
        notice_name = f"au-{target[:12]}"
        notices = run / "engine-runtime/notices"
        notices.mkdir(parents=True)
        (notices / f"{notice_name}.json").write_text(json.dumps({"revision": target}))
        (notices / f"{notice_name}.offers.jsonl").write_text(json.dumps({
            "id": notice_name, "launch_id": launch,
        }) + "\n")
        if boundary == "posttooluse-output":
            payload = {"hookSpecificOutput": {"additionalContext": f"KOGEN AUDIT intent {target[:12]} is blocked"}}
        else:
            payload = {"decision": "block", "reason": f"read {session}/reports/{target}/report.json"}
        raw = json.dumps(payload).encode("utf-8")
        now = "2026-01-01T00:00:03+00:00"
        receipt = {
            "schema": "kogen.feedback-delivery/v1", "boundary": boundary,
            "provider": provider or harness, "route": receipt_route or route,
            "root": str(session.parents[3]), "session_dir": str(session), "intent_id": intent_id,
            "revision": target, "launch_id": launch, "at": now,
            "payload_base64": base64.b64encode(raw).decode("ascii"), "byte_count": len(raw),
            "payload_sha256": hashlib.sha256(raw).hexdigest(),
        }
        receipt_path = run / "feedback-delivery/receipts.jsonl"
        receipt_path.parent.mkdir(parents=True)
        receipt_path.write_text(json.dumps(receipt) + "\n")
        events = [
            {"event": "turn_started", "turn": 1, "launch_id": launch,
             "at": "2026-01-01T00:00:01+00:00"},
            {"event": "turn_ended", "turn": 1, "at": "2026-01-01T00:00:04+00:00"},
            {"event": "audit_started", "revision": final, "at": "2026-01-01T00:00:05+00:00"},
        ]
        (run / "engine-runtime/events.jsonl").write_text("".join(json.dumps(event) + "\n" for event in events))
        return run, final, events

    def test_audit_delivery_uses_captured_harness_and_configured_route_separately(self):
        integrity = self.driver.integrity_module()
        for name, route, harness, boundary in (
            ("feedback-default-codex", "codex", "codex", "posttooluse-output"),
            ("feedback-hybrid-codex", "optimum", "codex", "posttooluse-output"),
            ("feedback-hybrid-claude", "hybrid", "claude", "stop-output"),
        ):
            with self.subTest(route=route, harness=harness):
                run, final, events = self.feedback_identity_case(
                    name, route=route, harness=harness, boundary=boundary
                )
                ok, detail = integrity.audit_feedback_delivery(run, final, events)
                self.assertTrue(ok, detail)

        for name, provider, receipt_route in (
            ("feedback-wrong-provider", "optimum", "optimum"),
            ("feedback-wrong-route", "codex", "default"),
            ("feedback-wrong-provider-for-claude", "hybrid", "hybrid"),
        ):
            with self.subTest(name=name):
                route = "hybrid"
                harness = "claude" if name.endswith("claude") else "codex"
                boundary = "stop-output" if harness == "claude" else "posttooluse-output"
                run, final, events = self.feedback_identity_case(
                    name, route=route, harness=harness, boundary=boundary,
                    provider=provider, receipt_route=receipt_route,
                )
                ok, detail = integrity.audit_feedback_delivery(run, final, events)
                self.assertFalse(ok, f"wrong provider/route accepted: {detail}")

        for missing in ("harness", "route"):
            with self.subTest(missing=missing):
                run, final, events = self.feedback_identity_case(
                    f"feedback-missing-{missing}", route="optimum", harness="codex",
                    boundary="posttooluse-output",
                )
                config_path = run / "config-record.json"
                config = json.loads(config_path.read_text())
                config.pop(missing)
                config_path.write_text(json.dumps(config))
                ok, detail = integrity.audit_feedback_delivery(run, final, events)
                self.assertFalse(ok, f"missing {missing} metadata unexpectedly accepted: {detail}")

    def test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast(self):
        """Wrong control: the one question is never answered because the case script has
        no message. The session settles awaiting_answers and drive() fails fast instead
        of waiting out the bound; no manifest is written."""
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.info["fixture"], capture_output=True,
                              text=True, check=True).stdout.strip()
        fixture = self.fixture("smoke", self.brief("smoke"))
        flawed = self.rehomed_template("flawed", head)
        self.script([[{"create_draft": {"template": str(flawed)}},
                      {"ask": {"number": 1, "question": "Which punctuation?", "recommendation": "a period",
                               "evidence": "unproven: the Shaper decides"}}]])
        spec = self.case_spec("smoke", [{"step": "start", "brief": "brief.md"}], end="ready")
        started = self.driver.monotonic_now()
        receipt = self.driver.drive("smoke", fixture, spec, harness="codex", route="codex", max_seconds=120,
                                    native_binding=False)
        self.assertEqual("TurnEndFailFast", (receipt["failure"] or {}).get("type"), receipt["failure"])
        self.assertIn("awaiting_answers", receipt["failure"]["message"])
        self.assertLess(self.driver.monotonic_now() - started, 100, "fail-fast must not run out the bound")
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_smoke_wrong_control_missing_feedback_delivery_fails(self):
        """Wrong control: the flawed first Draft is never audited inside the Shaping
        Controller's turn (no Stop feedback, no repair). run_smoke() must fail and write
        no manifest."""
        external = self.root / "failed-run-fixtures"
        with patch.dict(os.environ, {self.driver.FIXTURE_ROOT_ENV: str(external)}), self.record_spawns():
            status = self.run_smoke("codex", audited=False)
        self.assertEqual(1, status, self.output.getvalue())
        self.assertEqual(0, len(self.frames()))
        self.assertFalse((self.driver.RUNTIME / "evidence-manifest.json").exists())
        self.assertEqual([], list(external.iterdir()), "a failed but settled run must remove its owned fixture")
        cleanup = json.loads((self.driver.RUNTIME / "runs/smoke/fixture-cleanup.json").read_text())
        self.assertTrue(cleanup["removed"], cleanup)
        run = self.driver.RUNTIME / "runs" / "smoke"
        final = json.loads((run / "status-final.json").read_text())
        self.assertEqual("blocked", final["state"], final)
        before_cleanup = run / "before-cleanup"
        self.assertEqual("blocked", json.loads((before_cleanup / "status-final.json").read_text())["state"])
        self.assertTrue((before_cleanup / "draft" / "scenarios.yaml").is_file())
        reports = [json.loads(path.read_text()) for path in
                   (before_cleanup / "shaping-audits").glob("*/report.json")]
        self.assertTrue(reports)
        self.assertTrue(any(
            "proof-selector-missing test/greeting_test.exs" in finding.get("id", "")
            for report in reports for finding in report.get("findings", [])
        ), reports)
        self.assertTrue(list((before_cleanup / "shaping-audits").glob("*/report.md")))
        engine = json.loads((run / "engine-run.json").read_text())
        self.assertTrue(any(command.get("state") == "blocked" and
                            (command.get("error") or {}).get("code") == "not_ready"
                            for command in engine["commands"]), engine["commands"])
        self.assertFalse(any("smoke-cleanup-cancel" in " ".join(command["argv"])
                             for command in engine["commands"]))

    NEW_CHECKS = ("first-answer-original-turn-identified", "first-answer-steered-into-original-turn",
                  "first-answer-recorded-in-original-turn")

    def wrong_control_run(self, **script):
        """Runs the real smoke with a wrong provider script; the driver must refuse it
        and write no manifest."""
        with self.record_spawns():
            status = self.run_smoke("codex", **script)
        self.assertEqual(1, status, self.output.getvalue())
        self.assertEqual(0, len(self.frames()))
        self.assertFalse((self.driver.RUNTIME / "evidence-manifest.json").exists())
        run = self.driver.RUNTIME / "runs" / "smoke"
        return run, json.loads((run / "smoke-result.json").read_text())

    def integrity_check(self, run):
        integrity = self.driver.integrity_module()
        events = self.driver.read_events_file(run / "engine-runtime/events.jsonl")
        first = json.loads((run / "messages.json").read_text())[0]
        answers = self.driver.shaper_answers_section((run / "draft/questions.md").read_text())
        return integrity.validate_first_answer_delivery(run, first, events, answers)

    def test_smoke_correct_control_first_answer_is_steered_and_recorded_in_the_original_turn(self):
        with self.record_spawns():
            self.assertEqual(0, self.run_smoke("codex"), self.output.getvalue())
        run = self.driver.RUNTIME / "runs" / "smoke"
        result = json.loads((run / "smoke-result.json").read_text())
        for name in self.NEW_CHECKS:
            self.assertTrue(result["checks"][name]["ok"], result["checks"][name])
        first = json.loads((run / "messages.json").read_text())[0]
        self.assertIsNotNone(first["running_turn"]["launch_id"])
        offers = [json.loads(line) for line in (run / "engine-runtime/inputs/0002.offers.jsonl").read_text().splitlines()]
        self.assertEqual([("steer", first["running_turn"]["launch_id"])], [(o["via"], o["launch_id"]) for o in offers])
        self.integrity_check(run)

    def test_smoke_wrong_control_steering_disabled_first_answer_recorded_only_on_fallback_resume(self):
        """Wrong control (the reviewer's counterexample): no steer delivery, so the first
        answer is offered and recorded only by a later fallback resume; three turns run
        and every other check still passes."""
        run, result = self.wrong_control_run(steer=False, record_in_turn=False)
        failed = {name for name, item in result["checks"].items() if not item["ok"]}
        self.assertEqual({"first-answer-steered-into-original-turn", "first-answer-recorded-in-original-turn"}, failed, result)
        started = [e for e in self.driver.read_events_file(run / "engine-runtime/events.jsonl") if e.get("event") == "turn_started"]
        self.assertGreaterEqual(len(started), 3)
        with self.assertRaisesRegex(ValueError, "never steered"):
            self.integrity_check(run)

    def test_smoke_wrong_control_offer_exists_but_recording_only_in_a_later_turn(self):
        """Wrong control: the steer hook offered the answer to the original turn, but that
        turn never recorded it; the runner had to re-send it in a later launch."""
        run, result = self.wrong_control_run(steer=True, record_in_turn=False)
        failed = {name for name, item in result["checks"].items() if not item["ok"]}
        self.assertEqual({"first-answer-recorded-in-original-turn"}, failed, result)
        with self.assertRaisesRegex(ValueError, "needed a later launch"):
            self.integrity_check(run)

    def evidence_copy(self, run, name):
        target = self.root / name
        shutil.copytree(run, target)
        return target

    def test_smoke_correct_control_audit_feedback_is_delivered_to_a_root_launch_before_the_repair(self):
        with self.record_spawns():
            self.assertEqual(0, self.run_smoke("codex"), self.output.getvalue())
        run = self.driver.RUNTIME / "runs" / "smoke"
        result = json.loads((run / "smoke-result.json").read_text())
        check = result["checks"]["audit-feedback-delivered-before-repair"]
        self.assertTrue(check["ok"], check)
        self.assertRegex(check["detail"], r"posttooluse-output|stop-output")
        hooks = [json.loads(line) for line in (run / "shaping-audits" / "hook.jsonl").read_text().splitlines()]
        self.assertEqual("block", hooks[0]["decision"])
        self.assertTrue(hooks[0]["blocking"])
        self.assertEqual("allow", hooks[-1]["decision"])
        self.assertNotEqual(hooks[0]["revision"], hooks[-1]["revision"])

    def test_smoke_wrong_control_feedback_suppressed_but_repair_and_report_progression_remain(self):
        """Wrong control (the reviewer's counterexample): the earlier report has a blocking
        finding, the repaired revision has a ready report, the Draft is repaired in the same
        session, but the outer relay suppresses only delivered feedback. The producer's
        journal and independent repair remain intact."""
        with self.record_spawns(), patch.dict(
            self.driver.ENGINE_ENV, {"KOGEN_SHAPING_SUPPRESS_FEEDBACK_OUTPUT": "1",
                                    "KOGEN_SHAPING_QUIET_MS": "1500",
                                    "KOGEN_SHAPING_POLL_MS": "200"}
        ):
            self.assertEqual(1, self.run_smoke("codex", repair_independently=True), self.output.getvalue())
        run = self.driver.RUNTIME / "runs" / "smoke"
        messages = [m["text"] for m in json.loads((run / "messages.json").read_text())]
        events = self.driver.read_events_file(run / "engine-runtime/events.jsonl")
        final_status = json.loads((run / "status-final.json").read_text())
        presented = final_status.get("presented") or {}
        self.assertEqual("ready", final_status.get("state"),
                         f"independent repair did not reach ready: status={final_status!r}; run={run}")
        self.assertTrue(presented.get("id") and presented.get("revision"),
                        f"ready status lacks a current presentation: {final_status!r}; run={run}")
        revision = presented["revision"]
        self.assertTrue((run / "draft/scenarios.yaml").is_file(), "final Draft must survive fixture cleanup")
        self.assertTrue(list((run / "shaping-audits").glob("*/report.json")), "full reports must survive cleanup")
        self.assertTrue(list((run / "shaping-audits").glob("*/report.md")), "Markdown reports must survive cleanup")

        def failed_after(name, mutate):
            copy = self.evidence_copy(run, name)
            mutate(copy)
            result = self.driver.smoke_assertions(copy, messages)
            failed = {key for key, item in result["checks"].items() if not item["ok"]}
            return copy, failed

        hooks = [json.loads(line) for line in (run / "shaping-audits" / "hook.jsonl").read_text().splitlines()]
        self.assertTrue(any(item.get("decision") == "block" and item.get("blocking") for item in hooks))
        self.assertTrue(any(item.get("revision") == revision and item.get("decision") == "allow" for item in hooks))
        offers = [json.loads(line) for path in (run / "engine-runtime" / "notices").glob("*.offers.jsonl")
                  for line in path.read_text().splitlines() if line.strip()]
        first_block = next(item for item in hooks if item.get("decision") == "block" and item.get("blocking"))
        original_launch = next(item["launch_id"] for item in events if item.get("event") == "turn_started")
        self.assertTrue(any(offer.get("id") == "au-" + first_block["revision"][:12] and
                            offer.get("launch_id") == original_launch and offer.get("via") == "steer"
                            for offer in offers),
                        "suppression must retain the original launch's offer of the blocked revision")
        reports = [json.loads(path.read_text()) for path in (run / "shaping-audits").glob("*/report.json")]
        self.assertTrue(any(report.get("revision") != revision and report.get("findings")
                            for report in reports), "the earlier blocking report must remain retained")
        self.assertTrue(any(report.get("revision") == revision and report.get("scope") == "full"
                            and report.get("readiness") == "ready" for report in reports),
                        "the independent repair must still produce a later full-ready report")
        feedback = run / "feedback-delivery" / "receipts.jsonl"
        self.assertTrue(not feedback.exists() or not feedback.read_bytes(), "suppressed output must have no delivery receipt")
        copy, failed = failed_after("suppressed", lambda _c: None)
        self.assertEqual({"audit-feedback-delivered-before-repair"}, failed)
        with self.assertRaisesRegex(ValueError, "actual output receipts"):
            self.driver.integrity_module().validate_audit_feedback_delivery(copy, revision, events)
        # Without the earlier blocking report there is nothing to deliver: also refused.
        def drop_findings(copy):
            for path in (copy / "shaping-audits").glob("*/report.json"):
                report = json.loads(path.read_text())
                if report["revision"] != revision:
                    path.write_text(json.dumps({**report, "findings": []}))
        _, failed = failed_after("no-findings", drop_findings)
        self.assertIn("audit-feedback-delivered-before-repair", failed)

    def test_smoke_assertions_reject_missing_evidence(self):
        """The analysis itself is a wrong-control target: an empty run fails every check."""
        run = self.root / "empty-run"; run.mkdir()
        result = self.driver.smoke_assertions(run, ["a", "b"])
        self.assertTrue(result["failures"])
        for name in ("start-returns-running", "answers-recorded-verbatim-with-input-tokens",
                     "resumed-provider-ids-match", "status-presented-id",
                     "earlier-revision-report-has-findings", "later-full-report-ready-for-final-revision",
                     "audit-feedback-delivered-before-repair", *self.NEW_CHECKS):
            self.assertFalse(result["checks"][name]["ok"], name)

    def test_smoke_wrong_control_expect_spawn_fails_the_rehearsal(self):
        """Wrong control for the spawn rule: a recorded expect transport (or an unsupported
        kogen.shape flag) is reported as a violation; engine commands are not."""
        engine = [["mix", "kogen.shape", "--brief", "b.md", "--request-id", "smoke"],
                  ["mix", "kogen.shape", "0197-x"],
                  ["mix", "kogen.shape", "0197-x", "--approve", "p-1-abcdef012345"],
                  ["mix", "kogen.shape", "0197-x", "--cancel"],
                  ["git", "status", "--porcelain"]]
        self.assertEqual([], spawn_violations(engine))
        self.assertTrue(spawn_violations(engine + [["expect", "shape_transport.exp", "/fixture"]]))
        self.assertTrue(spawn_violations([["mix", "kogen.shape", "--headless", "b.md"]]))
        self.assertTrue(spawn_violations([["/usr/bin/expect", "-f", "x"]]))

    def test_smoke_fixture_pins_shaping_effort_low_on_each_route_and_rejects_unapplied_effort(self):
        """The tracked config's route for each harness gets Shaping effort low and cheap
        helpers, the auditor stays as configured, and an unpinned run fails."""
        tracked = (HERE.parents[2] / ".kogen" / "config.yaml").read_text()
        for harness, helper_model in (("codex", "gpt-6-luna"), ("claude", "claude-sonnet-5")):
            pinned = self.driver.pinned_smoke_config(tracked, harness)
            diff = list(difflib.unified_diff(tracked.splitlines(), pinned.splitlines(), n=0, lineterm=""))
            removed = [line for line in diff if line.startswith("-") and not line.startswith("---")]
            added = [line for line in diff if line.startswith("+") and not line.startswith("+++")]
            self.assertEqual(3, len(removed), removed)
            self.assertEqual(3, len(added), added)
            self.assertTrue(any("shaping:" in line and "effort: low" in line for line in added))
            self.assertTrue(all(f"{helper_model}, effort: low" in line for line in added[1:]), added)
            self.assertFalse(any("auditor" in line for line in removed + added), "the real auditor stays")
            self.assertRegex(pinned, rf"  {harness}:\n    harness: {harness}\n    shaping:\s*\{{[^}}]*effort: low\}}")
        with self.assertRaisesRegex(RuntimeError, "exactly one block-style codex route"):
            self.driver.pinned_smoke_config("routes:\n  codex-fake: {harness: codex}\n")
        without = "".join(line for line in tracked.splitlines(keepends=True) if not line.startswith("      expert:"))
        with self.assertRaisesRegex(RuntimeError, "no single flow-map expert helper line to pin"):
            self.driver.pinned_smoke_config(without, "codex")
        both = self.driver.smoke_files()[".kogen/config.yaml"]
        self.assertEqual(2, len(re.findall(r"shaping:\s*\{[^}]*effort: low\}", both.split("  claude-dominant")[0])))

        def receipt(configured):
            return {"configured_profiles": {"normalized": {"shaping": {"effort": configured}}}}
        self.driver.require_smoke_effort(receipt("low"))
        with self.assertRaisesRegex(RuntimeError, "Shaping effort not applied"):
            self.driver.require_smoke_effort(receipt("medium"))


if __name__ == "__main__":
    unittest.main()
