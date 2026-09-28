#!/usr/bin/env python3
"""Offline orchestration rehearsal for the standalone smoke case
(driver.py --smoke): the real driver.run_smoke() -> setup_fixture() ->
drive() -> write_smoke_manifest() -> integrity.validate_smoke_manifest()
path, with only the provider transport (Popen) and the mix compile/mix run
subprocess boundary faked -- never a reimplementation of that logic.
"""
import contextlib
import difflib
import importlib.util
import io
import json
import re
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
DRIVER_PATH = HERE / "driver.py"


def fake_parser_stdout(contents):
    try:
        return json.dumps(json.loads(contents)).encode()
    except (TypeError, json.JSONDecodeError):
        return b'{"id":"parser-preflight"}'


class Child:
    _next_pid = 51000
    def __init__(self):
        self.returncode = None
        self.pid = Child._next_pid
        Child._next_pid += 1
    def poll(self): return self.returncode
    def wait(self, timeout=None): self.returncode = 0; return 0
    def terminate(self): self.returncode = -15
    def kill(self): self.returncode = -9


class Clock:
    def __init__(self): self.wall = 0; self.mono = 0
    def time(self): self.wall += 1; return self.wall
    def monotonic(self): self.mono += 1; return self.mono
    def sleep(self, seconds): self.mono += max(1, seconds)


class DriverSmokeRehearsalTest(unittest.TestCase):
    def test_smoke_bounds_and_correlation_are_unchanged(self):
        self.assertEqual(self.driver.SMOKE_MAX_SECONDS, 300)
        self.assertEqual(self.driver.integrity_module().SMOKE_MAX_SECONDS, 300)
        receipt = {
            "scripted_replies": 0,
            "git_status": {"baseline_unchanged": True, "draft_exists": True},
            "source_identity": {"unchanged": True},
            "outcome": "completed",
            "correlation": {
                "exactly_one_root": True,
                "all_owned_terminal": True,
                "all_profiles_match": True,
            },
            "cleanup": [{"all_reaped": True}],
        }
        self.assertTrue(self.driver.case_succeeded(receipt))
        receipt["correlation"]["exactly_one_root"] = False
        self.assertFalse(self.driver.case_succeeded(receipt))
        receipt["correlation"]["exactly_one_root"] = True
        receipt["correlation"]["all_profiles_match"] = False
        self.assertFalse(self.driver.case_succeeded(receipt))

    def setUp(self):
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        self.temp = tempfile.TemporaryDirectory(prefix="kogen-smoke-rehearsal-")
        # Resolved: the driver resolves RUNTIME, so an unresolved /var tempdir
        # (macOS symlink to /private/var) would sit outside PROJECT.
        self.root = Path(self.temp.name).resolve()
        self.sessions = self.root / "sessions"; self.sessions.mkdir()
        self.project = self.root / "project"
        # write_smoke_manifest() requires every manifested path to live
        # under PROJECT, matching the real layout (.kogen/runtime/... inside
        # the checkout).
        self.runtime = self.project / ".kogen" / "runtime" / "smoke-rehearsal"
        self.runtime.mkdir(parents=True)
        (self.project / "lib").mkdir(parents=True)
        (self.project / "lib" / "app.ex").write_text("defmodule App do end\n")
        (self.project / ".kogen").mkdir(parents=True, exist_ok=True)
        # Block-style routes like the tracked config: the smoke fixture pins
        # only the codex route's Shaping effort to low.
        (self.project / ".kogen" / "config.yaml").write_text(
            "default_route: claude-fake\nroutes:\n"
            "  claude-fake:\n    harness: claude\n    shaping:   {model: fake-claude, effort: high}\n"
            "  codex-fake:\n    harness: codex\n    shaping:   {model: fake-model, effort: medium}\n"
            "    auditor:   {model: fake-model, effort: high}\n    helpers:\n"
            "      scout:  {model: fake-model, effort: low}\n"
            "      worker: {model: fake-model, effort: high}\n"
            "      expert: {model: fake-model, effort: high}\n")
        # Drafts are git-ignored in the real repo; match that so the smoke
        # fixture's own baseline_unchanged git-status check behaves as it
        # does for a real fixture once the transport saves its Draft.
        (self.project / ".gitignore").write_text(".kogen/intents/drafts/\n.kogen/runtime/\n")
        old_runtime = os.environ.get("KOGEN_SHAPING_EVALUATION_RUNTIME")
        os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = str(self.runtime)
        # The real elixir YAML-parser subprocess is faked below (see run()'s
        # argv[0]=="elixir" branch); this just satisfies the pre-flight
        # nonempty-existing-directory check the driver does before spawning it.
        old_code_paths = os.environ.get("KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS")
        os.environ["KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS"] = json.dumps([str(self.root)])
        spec = importlib.util.spec_from_file_location("smoke_rehearsal_driver", DRIVER_PATH)
        self.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.driver)
        self.driver.SESSION_ROOT = self.sessions
        self.driver.PROJECT = self.project
        if old_runtime is None: self.addCleanup(os.environ.pop, "KOGEN_SHAPING_EVALUATION_RUNTIME")
        else: self.addCleanup(os.environ.__setitem__, "KOGEN_SHAPING_EVALUATION_RUNTIME", old_runtime)
        if old_code_paths is None: self.addCleanup(os.environ.pop, "KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS")
        else: self.addCleanup(os.environ.__setitem__, "KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", old_code_paths)

    def tearDown(self): self.temp.cleanup()

    def run_smoke(self, *, missing_answer=False, corrupt_manifest_call=None, hook_files=False):
        """Exercises the real driver.run_smoke() end to end offline: real
        setup_fixture (rsync/git/prerequisite control for real; only `mix
        compile` and `mix run` are faked), real drive(), real
        write_smoke_manifest()/validate_smoke_manifest()."""
        clock = Clock()
        launches = []
        rollout = self.sessions / "rollout-smoke.jsonl"
        fixture_holder = {}

        def real_answer_present():
            return not missing_answer

        def append_startup(fixture):
            if hook_files:
                hook_dir = fixture / ".kogen/runtime/shaping-audits/eval-smoke"
                hook_dir.mkdir(parents=True, exist_ok=True)
                (hook_dir / "hook.jsonl").write_text("{}\n")
                (hook_dir / ("a" * 64) / "report.json").parent.mkdir(parents=True, exist_ok=True)
                (hook_dir / ("a" * 64) / "report.json").write_text("{}\n")
            events = [
                {"type": "session_meta", "payload": {"id": "root-smoke", "cwd": str(fixture), "source": "cli"}},
                {"type": "turn_context", "payload": {"turn_id": "startup", "model": "fake-model", "effort": "low"}},
                {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                       "content": [{"text": "Hello! What punctuation should I use?"}]}},
                {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "startup"}},
            ]
            rollout.write_text("".join(json.dumps(e) + "\n" for e in events))
            # The transport is faked; the driver itself never writes the
            # Draft, so this stands in for what a real Shaping session saves
            # after its startup turn (a draft, unapproved intent.yaml plus a
            # not-yet-answered questions.md).
            draft = fixture / ".kogen/intents/drafts/eval-smoke"
            draft.mkdir(parents=True, exist_ok=True)
            fixture_holder["intent"] = {
                "id": "01990000-0000-7000-8000-0000000005c0", "slug": "eval-smoke", "title": "Smoke",
                "status": "draft",
                "shaped_against": {"branch": "main", "head": "frozen-head"},
                "shaping": {"harness": "codex", "model": "fake-model", "effort": "low", "started": "smoke-visit"},
                "shaping_continuations": [], "may_change_guarded_paths": ["evidence/**"],
            }
            (draft / "intent.yaml").write_text(json.dumps(fixture_holder["intent"], indent=2) + "\n")
            (draft / "questions.md").write_text("What punctuation should I use?\n")

        def append_reply(fixture, text):
            turn = "turn-1"
            with rollout.open("a") as handle:
                handle.write(json.dumps({"type": "turn_context", "payload": {"turn_id": turn, "model": "fake-model", "effort": "low"}}) + "\n")
                handle.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user",
                                                                               "content": [{"text": text}],
                                                                               "internal_chat_message_metadata_passthrough": {"turn_id": turn}}}) + "\n")
                handle.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"text": "Understood."}]}}) + "\n")
                handle.write(json.dumps({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": turn}}) + "\n")
            if real_answer_present():
                # The scripted answer reached its expected end state: the
                # smoke Draft now carries every required file.
                draft = fixture / ".kogen/intents/drafts/eval-smoke"
                (draft / "scenarios.yaml").write_text("[]\n")
                (draft / "intent.yaml").write_text(json.dumps(fixture_holder["intent"], indent=2) + "\n")
            # missing_answer wrong control: the final scripted turn completes
            # but scenarios.yaml is deliberately never saved, so
            # turn_end_decision must fire fail-fast for this case.

        def popen(argv, **_kwargs):
            launches.append(argv)
            receipt_path = _kwargs.get("env", {}).get("KOGEN_CODEX_CONTEXT_RECEIPT")
            if receipt_path:
                Path(receipt_path).write_text(json.dumps({
                    "executable": sys.executable,
                    "args": ["-c", "raise SystemExit('rehearsal context is not executed')"],
                    "env": {},
                }))
            if Path(argv[1]).name == "shape_transport.exp":
                fixture = Path(argv[2])
                fixture_holder["fixture"] = fixture
                append_startup(fixture)
            elif Path(argv[1]).name == "resume_transport.exp":
                fixture = Path(argv[2])
                text = Path(argv[4]).read_text()
                append_reply(fixture, text)
            return Child()

        def run(argv, **kwargs):
            class Result:
                returncode = 0; stdout = ""; stderr = ""
            result = Result()
            if argv[:2] == ["mix", "compile"]:
                return result
            if argv and argv[0] == "elixir":
                result.stdout = fake_parser_stdout(kwargs.get("input", b""))
                return result
            if argv[:2] == ["mix", "run"]:
                code = argv[-1]
                if "IO.write(route_name)" in code:
                    result.stdout = "smoke-codex-route"
                else:
                    # The configured effort comes from the fixture's own
                    # config, so an unpinned fixture fails the effort check.
                    config = (Path(kwargs["cwd"]) / ".kogen/config.yaml").read_text()
                    effort = re.search(r"harness: codex\n    shaping:\s*\{[^}]*effort: (\w+)", config).group(1)
                    result.stdout = json.dumps({
                        "shaping": {"model": "fake-model", "effort": effort},
                        "helpers": {name: {"model": "fake-model", "effort": "low"} for name in ("scout", "worker", "expert")},
                    })
                return result
            return real_run(argv, **kwargs)

        # Patching subprocess.Popen affects the whole shared subprocess module,
        # including subprocess.run's own internals, so real rsync/git/mix
        # compile-preflight calls capture the unpatched Popen class first and
        # drive their own communicate() cycle instead of subprocess.run.
        real_popen_class = self.driver.subprocess.Popen

        def real_run(argv, **kwargs):
            check = kwargs.pop("check", False)
            text = kwargs.pop("text", False)
            capture_output = kwargs.pop("capture_output", False)
            timeout = kwargs.pop("timeout", None)
            if capture_output:
                kwargs["stdout"] = self.driver.subprocess.PIPE
                kwargs["stderr"] = self.driver.subprocess.PIPE
            proc = real_popen_class(argv, text=text, **kwargs)
            stdout, stderr = proc.communicate(timeout=timeout)
            if check and proc.returncode:
                raise self.driver.subprocess.CalledProcessError(proc.returncode, argv, output=stdout, stderr=stderr)

            class Result:
                pass
            result = Result()
            result.returncode = proc.returncode
            result.stdout = stdout
            result.stderr = stderr
            return result

        with patch.object(self.driver.time, "time", clock.time), \
             patch.object(self.driver.time, "monotonic", clock.monotonic), \
             patch.object(self.driver.time, "sleep", clock.sleep), \
             patch.object(self.driver.subprocess, "Popen", popen), \
             patch.object(self.driver.subprocess, "run", run), \
             patch.object(self.driver, "owned_process_tree", lambda _fixture: []), \
             patch.object(self.driver, "reap_owned_cli",
                          lambda *_a: {"roots": [], "before": [], "actions": [], "remaining_pids": [], "all_reaped": True}):
            status = self.driver.run_smoke()
        return status, launches

    def test_smoke_rehearsal_dispatches_real_functions_and_manifests_once(self):
        trace_path = self.root / "trace.txt"
        with patch.dict(os.environ, {"KOGEN_REHEARSAL_TRACE": str(trace_path)}):
            status, launches = self.run_smoke()

        self.assertEqual(0, status)
        self.assertTrue(any(Path(argv[1]).name == "shape_transport.exp" for argv in launches))
        self.assertTrue(any(Path(argv[1]).name == "resume_transport.exp" for argv in launches))

        # driver-turn-end-replay's fail-fast never fired on the passing path.
        stdout = self.output.getvalue()
        self.assertNotIn("TurnEndFailFast", stdout)

        manifest_frames = [line for line in stdout.splitlines() if line.startswith("KOGEN_TARGET_EVIDENCE_MANIFEST\t")]
        self.assertEqual(1, len(manifest_frames), "the manifest frame must be written and printed exactly once")
        locator = json.loads(manifest_frames[0].split("\t", 1)[1])
        manifest_path = self.project / locator["manifest_path"]
        self.assertTrue(manifest_path.is_file())

        fixture = self.runtime / "smoke"
        self.assertFalse(fixture.exists(), "the fixture must be cleaned up on a clean exit")

        trace = trace_path.read_text().splitlines() if trace_path.is_file() else []
        self.assertIn("driver.run_smoke", trace)
        self.assertIn("driver.setup_fixture", trace)
        self.assertIn("Kogen.ShapingEvaluation.Integrity.validate_smoke_manifest", trace)

    def test_smoke_fixture_pins_codex_shaping_effort_low_and_rejects_unapplied_effort(self):
        """The tracked config's one codex route gets Shaping effort low and
        nothing else changes; a session observed at another effort fails."""
        tracked = (HERE.parents[2] / ".kogen" / "config.yaml").read_text()
        pinned = self.driver.pinned_smoke_config(tracked)
        diff = list(difflib.unified_diff(tracked.splitlines(), pinned.splitlines(), n=0, lineterm=""))
        removed = [line for line in diff if line.startswith("-") and not line.startswith("---")]
        added = [line for line in diff if line.startswith("+") and not line.startswith("+++")]
        self.assertEqual(removed, [
            "-    shaping:   {model: gpt-6-sol, effort: medium}",
            "-    auditor:   {model: gpt-6-sol, effort: high}",
            "-      worker: {model: gpt-6-luna, effort: high}",
            "-      expert: {model: gpt-6-sol, effort: high}",
        ])
        self.assertEqual(added, [
            "+    shaping:   {model: gpt-6-sol, effort: low}",
            "+      worker: {model: gpt-6-luna, effort: low}",
            "+      expert: {model: gpt-6-luna, effort: low}",
        ])
        def split_codex(text):
            before, rest = text.split("  codex:\n", 1)
            codex_block, after = rest.split("  claude-dominant-adversarial-codex:\n", 1)
            return before, codex_block, after

        tracked_before, tracked_codex, tracked_after = split_codex(tracked)
        pinned_before, pinned_codex, pinned_after = split_codex(pinned)
        self.assertFalse(any(line.startswith("    auditor:") for line in pinned_codex.splitlines()))
        self.assertEqual(pinned_before, tracked_before)
        self.assertEqual(pinned_after, tracked_after)
        self.assertRegex(pinned, r"  codex:\n    harness: codex\n    shaping:\s*\{[^}]*effort: low\}")
        with self.assertRaisesRegex(RuntimeError, "exactly one block-style codex route"):
            self.driver.pinned_smoke_config("routes:\n  codex-fake: {harness: codex}\n")

        def without_codex_line(prefix):
            kept = [line for line in tracked_codex.splitlines(keepends=True) if not line.startswith(prefix)]
            self.assertEqual(len(kept), len(tracked_codex.splitlines()) - 1)
            return (tracked_before + "  codex:\n" + "".join(kept)
                    + "  claude-dominant-adversarial-codex:\n" + tracked_after)

        with self.assertRaisesRegex(RuntimeError, "^smoke: the codex route has no auditor entry to remove$"):
            self.driver.pinned_smoke_config(without_codex_line("    auditor:"))
        with self.assertRaisesRegex(
                RuntimeError, "^smoke: the codex route has no single flow-map expert helper line to pin$"):
            self.driver.pinned_smoke_config(without_codex_line("      expert:"))

        def receipt(configured, observed):
            return {"configured_profiles": {"normalized": {"shaping": {"effort": configured}}},
                    "correlation": {"owned": [{"source": "cli", "efforts": observed}]}}
        self.driver.require_smoke_effort(receipt("low", ["low"]))
        for configured, observed in (("medium", ["medium"]), ("low", ["medium"]), ("low", ["low", "medium"])):
            with self.assertRaisesRegex(RuntimeError, "Shaping effort not applied"):
                self.driver.require_smoke_effort(receipt(configured, observed))

    def test_smoke_manifest_ignores_shaping_audit_files(self):
        first_status, _ = self.run_smoke()
        self.assertEqual(0, first_status)
        frames = [line for line in self.output.getvalue().splitlines()
                  if line.startswith("KOGEN_TARGET_EVIDENCE_MANIFEST\t")]
        self.assertEqual(1, len(frames))
        first_locator = json.loads(frames[0].split("\t", 1)[1])
        first_manifest = self.project / first_locator["manifest_path"]
        first_payload = json.loads(first_manifest.read_text())
        first_paths = {entry["path"] for entry in first_payload["required_evidence"]}
        manifest = self.runtime / "evidence-manifest.json"
        if manifest.exists():
            manifest.unlink()
        runtime = self.runtime
        shutil.rmtree(runtime / "runs", ignore_errors=True)
        for child in self.sessions.iterdir():
            if child.is_file() or child.is_symlink():
                child.unlink()
            elif child.is_dir():
                shutil.rmtree(child)
        self.output.seek(0)
        self.output.truncate(0)
        second_status, _ = self.run_smoke(hook_files=True)
        self.assertEqual(0, second_status)
        frames = [line for line in self.output.getvalue().splitlines()
                  if line.startswith("KOGEN_TARGET_EVIDENCE_MANIFEST\t")]
        self.assertEqual(1, len(frames))
        second_locator = json.loads(frames[0].split("\t", 1)[1])
        second_manifest = self.project / second_locator["manifest_path"]
        second_payload = json.loads(second_manifest.read_text())
        second_paths = {entry["path"] for entry in second_payload["required_evidence"]}
        self.assertEqual(first_paths, second_paths)
        self.assertFalse((self.runtime / "smoke").exists())

    def test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast(self):
        """Wrong control: the scripted reply is delivered but the Draft never
        reaches its expected end state (no scenarios.yaml) -- fail-fast must
        fire and no manifest may be written."""
        status, _launches = self.run_smoke(missing_answer=True)
        self.assertEqual(1, status)
        self.assertIn("TurnEndFailFast", self.output.getvalue())
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_smoke_wrong_control_invalid_manifest_is_rejected(self):
        """Wrong control: a smoke manifest missing its required evidence (or
        listing a nonexistent path) must be rejected by validate_smoke_manifest,
        never silently accepted."""
        integrity = self.driver.integrity_module()
        manifest_dir = self.root / "runtime2"
        manifest_dir.mkdir()
        (manifest_dir / "runs").mkdir()
        (manifest_dir / "runs" / "smoke").mkdir()
        manifest_path = manifest_dir / "evidence-manifest.json"
        manifest_path.write_text(json.dumps({
            "schema_version": 1,
            "required_evidence": [{"path": "does/not/exist.json", "sha256": "0" * 64}],
        }))
        with self.assertRaises(ValueError):
            integrity.validate_smoke_manifest(self.project, manifest_path)


if __name__ == "__main__":
    unittest.main()
