#!/usr/bin/env python3
"""Production hook-output boundary and receipt integrity controls for F2."""

import copy
import datetime
import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
RELAY = PROJECT / "priv/kogen/shaping/feedback_output.py"
STEER = PROJECT / "priv/kogen/shaping/steer_hook.py"
SETTINGS = PROJECT / "priv/kogen/claude_code/shaping-settings.json"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path, loader=SourceFileLoader(name, str(path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def iso(delta=0):
    value = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=delta)
    return value.isoformat()


class FeedbackDeliveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kogen-feedback-delivery-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        hook_dir = self.root / "priv/kogen/shaping"
        hook_dir.mkdir(parents=True)
        shutil.copy2(RELAY, hook_dir / RELAY.name)
        shutil.copy2(STEER, hook_dir / STEER.name)
        self.intent_id = "f2-feedback-fixture"
        self.slug = "f2-feedback-fixture"
        self.session_dir = self.root / ".kogen/runtime/shaping" / self.intent_id
        self.package = self.root / ".kogen/intents/drafts" / self.slug
        self.session_dir.mkdir(parents=True)
        self.package.mkdir(parents=True)
        (self.package / "intent.yaml").write_text(f"id: {self.intent_id}\nslug: {self.slug}\n")
        (self.package / "questions.md").write_text("# Questions\n\n## Shaper answers\n")
        self._write_session("optimum", "codex")
        self.revision = self._package_revision()
        notices = self.session_dir / "notices"
        notices.mkdir()
        self.notice_id = "au-" + self.revision[:12]
        (notices / f"{self.notice_id}.json").write_text(json.dumps({
            "revision": self.revision,
            "summary": "- audit-supported defect",
            "report": f".kogen/runtime/shaping-audits/{self.slug}/{self.revision}/report.json",
        }))
        audit_report = self.root / ".kogen/runtime/shaping-audits" / self.slug / self.revision
        audit_report.mkdir(parents=True)
        (audit_report / "report.json").write_text(json.dumps({
            "revision": self.revision,
            "findings": [{"id": "aud-f2", "severity": "blocking", "still_open": True}],
        }))
        self.launch_id = "launch-root-one"
        self.env = {
            "KOGEN_SHAPING_ROOT": str(self.root),
            "KOGEN_SHAPING_SESSION_DIR": str(self.session_dir),
            "KOGEN_SHAPING_INTENT_ID": self.intent_id,
            "KOGEN_SHAPING_LAUNCH_ID": self.launch_id,
            "KOGEN_SHAPING_ROUTE": "optimum",
        }

    def _write_session(self, route, harness, **extra):
        session = {
            "schema": 1,
            "intent_id": self.intent_id,
            "nonce": "a" * 32,
            "route": route,
            "harness": harness,
            **extra,
        }
        (self.session_dir / "session.json").write_text(json.dumps(session))

    def _write_accepted_input(self, number, kind, data, **extra):
        inputs = self.session_dir / "inputs"
        inputs.mkdir(exist_ok=True)
        number_text = f"{number:04}"
        input_id = f"in-{number_text}-{hashlib.sha256(data).hexdigest()[:8]}"
        (inputs / f"{number_text}.md").write_bytes(data)
        (inputs / f"{number_text}.json").write_text(json.dumps({
            "kind": kind,
            "id": input_id,
            "number": number,
            "sha256": hashlib.sha256(data).hexdigest(),
            **extra,
        }))
        return input_id

    def _run_steer_hook(self, env=None, payload=b"{}"):
        return subprocess.run(
            [sys.executable, str(RELAY), "posttooluse-output", "--producer", str(STEER)], input=payload,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, **(env or self.env)}, check=False,
        )

    def _recorded_input_entry(self, input_id, data, number=1):
        text = data.decode("utf-8")
        frame = json.dumps({
            "schema": "kogen.recorded-input/v1",
            "input_id": input_id,
            "byte_length": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "verbatim_text": text,
            "bytes_base64": __import__("base64").b64encode(data).decode("ascii"),
        }, ensure_ascii=False, separators=(",", ":"))
        return f"{number}. [input {input_id}]\n  ```kogen-recorded-input-v1\n  {frame}\n  ```\n"

    def _package_revision(self):
        digest = hashlib.sha256()
        for path in sorted(p for p in self.package.rglob("*") if p.is_file()):
            digest.update(path.relative_to(self.package).as_posix().encode() + b"\0")
            digest.update(path.read_bytes() + b"\0")
        return digest.hexdigest()

    def _registered_posttool_command(self):
        data = json.loads(SETTINGS.read_text())
        for entry in data["hooks"]["PostToolUse"]:
            for hook in entry["hooks"]:
                if hook.get("type") == "command":
                    return hook["command"]
        self.fail("shaping settings did not register the PostToolUse relay")

    def _fake_provider_turn(self):
        fake = load_module("fake_shaping_controller_for_feedback", HERE.parent / "fake_shaping_controller")
        fake.ROOT = str(self.root)
        fake.STATE_DIR = str(self.root / ".kogen/runtime/fake-provider")
        turn = fake.Turn.__new__(fake.Turn)
        turn.hooks = {"PostToolUse": self._registered_posttool_command()}
        turn.codex = True
        turn.transcript = None
        turn.id = "provider-session-root-one"
        return turn

    def _copy_run(self, destination):
        destination.mkdir()
        shutil.copytree(self.root / ".kogen/runtime/shaping-audits" / self.slug,
                        destination / "shaping-audits")
        shutil.copytree(self.session_dir / "notices", destination / "engine-runtime/notices")
        retained_receipts = destination / "feedback-delivery/receipts.jsonl"
        retained_receipts.parent.mkdir(parents=True)
        shutil.copy2(self.session_dir / "feedback-delivery/receipts.jsonl", retained_receipts)
        final_revision = "f" * 64
        final_report = destination / "shaping-audits" / self.slug / final_revision
        final_report.mkdir(parents=True)
        (final_report / "report.json").write_text(json.dumps({
            "revision": final_revision, "findings": [], "readiness": "ready",
        }))
        (destination / "config-record.json").write_text(json.dumps({
            "route": "optimum", "harness": "codex",
            "shaping_root": str(self.root), "shaping_intent_id": self.intent_id,
        }))
        now = datetime.datetime.now(datetime.timezone.utc)
        events = [
            {"event": "turn_started", "turn": 1, "launch_id": self.launch_id,
             "at": (now - datetime.timedelta(seconds=2)).isoformat()},
            {"event": "turn_ended", "turn": 1,
             "at": (now + datetime.timedelta(seconds=20)).isoformat()},
            {"event": "audit_started", "revision": final_revision,
             "at": (now + datetime.timedelta(seconds=3)).isoformat()},
        ]
        (destination / "engine-runtime/events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
        return events, final_revision

    def test_native_hook_output_and_receipt_identity_controls(self):
        integrity = load_module("feedback_integrity", HERE / "integrity.py")
        turn = self._fake_provider_turn()
        previous = os.environ.copy()
        try:
            os.environ.update(self.env)
            delivered = turn.run_hook("PostToolUse")
            context = delivered["hookSpecificOutput"]["additionalContext"]
            self.assertIn(f"KOGEN AUDIT {'a' * 32} {self.revision[:12]}", context)
            receipt_path = self.session_dir / "feedback-delivery/receipts.jsonl"
            receipts = [json.loads(line) for line in receipt_path.read_text().splitlines()]
            self.assertEqual(1, len(receipts))
            receipt = receipts[0]
            raw = __import__("base64").b64decode(receipt["payload_base64"], validate=True)
            self.assertEqual(receipt["byte_count"], len(raw))
            self.assertEqual(receipt["payload_sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual("posttooluse-output", receipt["boundary"])
            self.assertEqual("codex", receipt["provider"])
            self.assertEqual("optimum", receipt["route"])
            self.assertEqual(self.revision, receipt["revision"])
            self.assertEqual(self.launch_id, receipt["launch_id"])

            run = self.root / "retained-run"
            events, final_revision = self._copy_run(run)
            ok, detail = integrity.audit_feedback_delivery(run, final_revision, events)
            self.assertTrue(ok, detail)

            candidates = {
                "wrong root": lambda r: r.update(root=str(self.root / "other-root")),
                "wrong session": lambda r: r.update(session_dir=str(self.root / "other-session")),
                "wrong digest": lambda r: r.update(payload_sha256="0" * 64),
                "later launch": lambda r: r.update(launch_id="launch-after-root-turn"),
                "after repair": lambda r: r.update(at=iso(10)),
                "wrong revision": lambda r: r.update(revision="e" * 64),
            }
            for label, mutate in candidates.items():
                with self.subTest(label=label):
                    path = run / "feedback-delivery/receipts.jsonl"
                    altered = copy.deepcopy(receipt)
                    mutate(altered)
                    path.write_text(json.dumps(altered) + "\n")
                    ok, detail = integrity.audit_feedback_delivery(run, final_revision, events)
                    self.assertFalse(ok, f"{label} unexpectedly accepted: {detail}")

            # Exercise suppression after the real producer: its offer journal is
            # retained for the launch, while provider output and receipts stop.
            os.environ["KOGEN_SHAPING_LAUNCH_ID"] = "launch-suppressed"
            os.environ["KOGEN_SHAPING_SUPPRESS_FEEDBACK_OUTPUT"] = "1"
            suppressed = turn.run_hook("PostToolUse")
            self.assertEqual({}, suppressed)
            self.assertEqual(1, len(receipt_path.read_text().splitlines()))
            offers = (self.session_dir / "notices" / f"{self.notice_id}.offers.jsonl").read_text()
            self.assertIn(self.launch_id, offers)
            self.assertIn("launch-suppressed", offers)
            answer = "KOGEN SHAPER ANSWER exact accepted bytes"
            mixed = json.dumps({"hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": answer + "\n\n" + context,
            }}).encode()
            output = subprocess.run(
                ["python3", str(RELAY), "posttooluse-output"], input=mixed,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=os.environ.copy(), check=True,
            )
            self.assertEqual(answer, json.loads(output.stdout)["hookSpecificOutput"]["additionalContext"])
            self.assertEqual(1, len(receipt_path.read_text().splitlines()))
        finally:
            os.environ.clear()
            os.environ.update(previous)

    def test_stop_relay_records_only_forwarded_block_bytes(self):
        revision = "c" * 64
        route = "claude-dominant-adversarial-codex"
        self._write_session(route, "claude")
        payload = json.dumps({
            "decision": "block",
            "reason": f"blocking findings:\nreport: {self.root}/.kogen/runtime/shaping-audits/{self.slug}/{revision}/report.json",
        }, separators=(",", ":")).encode()
        environment = {
            **os.environ,
            **self.env,
            "KOGEN_SHAPING_ROUTE": route,
            "KOGEN_SHAPING_LAUNCH_ID": "launch-claude-stop",
        }
        completed = subprocess.run(
            ["python3", str(RELAY), "stop-output"], input=payload, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, check=True,
        )
        self.assertEqual(payload, completed.stdout)
        receipt_path = self.session_dir / "feedback-delivery/receipts.jsonl"
        receipt = json.loads(receipt_path.read_text().splitlines()[0])
        self.assertEqual("stop-output", receipt["boundary"])
        self.assertEqual("claude", receipt["provider"])
        self.assertEqual(route, receipt["route"])
        self.assertEqual(revision, receipt["revision"])
        self.assertEqual(hashlib.sha256(payload).hexdigest(), receipt["payload_sha256"])

        # The Claude route's accepted boundary is the actual Stop block. Its
        # output must match the earlier blocking report and precede repair.
        integrity = load_module("feedback_integrity_claude", HERE / "integrity.py")
        run = self.root / "claude-run"
        run.mkdir()
        (run / "feedback-delivery").mkdir()
        shutil.copy2(receipt_path, run / "feedback-delivery/receipts.jsonl")
        (run / "config-record.json").write_text(json.dumps({
            "route": route, "harness": "claude",
            "shaping_root": str(self.root), "shaping_intent_id": self.intent_id,
        }))
        reports = run / "shaping-audits"
        report_dir = reports / revision
        report_dir.mkdir(parents=True)
        (report_dir / "report.json").write_text(json.dumps({
            "revision": revision,
            "findings": [{"id": "aud-stop", "severity": "blocking", "still_open": True}],
        }))
        final_revision = "f" * 64
        final_dir = reports / final_revision
        final_dir.mkdir(parents=True)
        (final_dir / "report.json").write_text(json.dumps({
            "revision": final_revision, "findings": [], "readiness": "ready",
        }))
        block_at, repair_at = receipt["at"], iso(5)
        (reports / "hook.jsonl").write_text(json.dumps({
            "revision": revision, "decision": "block", "blocking": ["aud-stop"], "at": block_at,
        }) + "\n")
        events = [
            {"event": "turn_started", "turn": 1, "launch_id": "launch-claude-stop",
             "at": iso(-2)},
            {"event": "turn_ended", "turn": 1, "at": iso(20)},
            {"event": "audit_started", "revision": final_revision, "at": repair_at},
        ]
        (run / "engine-runtime").mkdir()
        (run / "engine-runtime/events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
        ok, detail = integrity.audit_feedback_delivery(run, final_revision, events)
        self.assertTrue(ok, detail)

        environment["KOGEN_SHAPING_SUPPRESS_FEEDBACK_OUTPUT"] = "1"
        suppressed = subprocess.run(
            ["python3", str(RELAY), "stop-output"], input=payload, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, check=True,
        )
        self.assertEqual(b"", suppressed.stdout)
        self.assertEqual(1, len(receipt_path.read_text().splitlines()))

    def test_root_steer_delivers_input_before_draft_and_copies_it_once_draft_exists(self):
        shutil.rmtree(self.package)
        brief = "The immutable first-turn brief.\n".encode()
        message = "Please retain the exact wording: café.\n".encode()
        followup = "And keep this second accepted message after the first.\n".encode()
        self._write_accepted_input(1, "brief", brief, interface="native")
        message_id = self._write_accepted_input(
            2, "message", message, open_questions=[{"number": 4}]
        )
        followup_id = self._write_accepted_input(
            3, "message", followup, open_questions=[{"number": 5}]
        )

        first = self._run_steer_hook()
        self.assertEqual(0, first.returncode, first.stderr.decode(errors="replace"))
        first_output = json.loads(first.stdout)
        context = first_output["hookSpecificOutput"]["additionalContext"]
        self.assertIn(f"KOGEN SHAPER ANSWER {'a' * 32} [input {message_id}]", context)
        self.assertIn("Open questions at receipt: 4", context)
        self.assertIn(message.decode(), context)
        self.assertIn(f"[input {followup_id}]", context)
        self.assertIn(followup.decode(), context)
        self.assertLess(context.index(message_id), context.index(followup_id))
        self.assertNotIn(brief.decode(), context)
        self.assertFalse((self.package / "evidence").exists())
        self.assertFalse((self.session_dir / "inputs/0001.offers.jsonl").exists())
        message_offers = self.session_dir / "inputs/0002.offers.jsonl"
        followup_offers = self.session_dir / "inputs/0003.offers.jsonl"
        for path, expected_id in ((message_offers, message_id), (followup_offers, followup_id)):
            offers = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([{"launch_id": self.launch_id, "via": "steer", "id": expected_id}], [
                {key: record[key] for key in ("launch_id", "via", "id")} for record in offers
            ])

        self.package.mkdir(parents=True)
        (self.package / "intent.yaml").write_text(f"id: {self.intent_id}\nslug: {self.slug}\n")
        questions = self.package / "questions.md"
        questions.write_text(
            "# Questions\n\n## Shaper answers\n"
            + self._recorded_input_entry(message_id, message)
            + self._recorded_input_entry(followup_id, followup, number=2)
        )

        same_launch = self._run_steer_hook()
        self.assertEqual(0, same_launch.returncode, same_launch.stderr.decode(errors="replace"))
        self.assertEqual(b"", same_launch.stdout)
        self.assertEqual(brief, (self.package / "evidence/brief.md").read_bytes())
        self.assertEqual(message, (self.package / "evidence/inputs/0002.md").read_bytes())
        self.assertEqual(followup, (self.package / "evidence/inputs/0003.md").read_bytes())
        self.assertEqual(1, len(message_offers.read_text().splitlines()))
        self.assertEqual(1, len(followup_offers.read_text().splitlines()))

        next_launch_env = {**self.env, "KOGEN_SHAPING_LAUNCH_ID": "launch-root-two"}
        next_launch = self._run_steer_hook(next_launch_env)
        self.assertEqual(0, next_launch.returncode, next_launch.stderr.decode(errors="replace"))
        self.assertEqual(b"", next_launch.stdout)
        self.assertEqual(1, len(message_offers.read_text().splitlines()))
        self.assertEqual(1, len(followup_offers.read_text().splitlines()))

        changed_record = self._recorded_input_entry(message_id, message).replace("café", "changed")
        questions.write_text(
            "# Questions\n\n## Shaper answers\n"
            + changed_record
            + self._recorded_input_entry(followup_id, followup, number=2)
        )
        recorded_env = {**self.env, "KOGEN_SHAPING_LAUNCH_ID": "launch-root-three"}
        recorded = self._run_steer_hook(recorded_env)
        self.assertEqual(0, recorded.returncode, recorded.stderr.decode(errors="replace"))
        recorded_context = json.loads(recorded.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn(message.decode(), recorded_context)
        self.assertNotIn(followup.decode(), recorded_context)
        self.assertEqual(2, len(message_offers.read_text().splitlines()))
        self.assertEqual(1, len(followup_offers.read_text().splitlines()))

    def test_receipt_requires_valid_canonical_harness_and_matching_route_without_changing_output(self):
        revision = "d" * 64
        payload = json.dumps({
            "decision": "block",
            "reason": f"blocking findings:\nreport: {self.root}/.kogen/runtime/shaping-audits/{self.slug}/{revision}/report.json",
        }, separators=(",", ":")).encode()
        receipt_path = self.session_dir / "feedback-delivery/receipts.jsonl"

        bad_sessions = [
            ("missing harness", {"route": "optimum", "harness": None}),
            ("invalid harness", {"route": "optimum", "harness": "hybrid"}),
            ("whitespace route", {"route": "   ", "harness": "codex"}),
            ("wrong intent", {"route": "optimum", "harness": "codex", "intent_id": "other-intent"}),
        ]
        for label, session_values in bad_sessions:
            with self.subTest(label=label):
                session_values = dict(session_values)
                intent_id = session_values.pop("intent_id", self.intent_id)
                session = {
                    "schema": 1, "intent_id": intent_id, "nonce": "a" * 32,
                    **{key: value for key, value in session_values.items() if value is not None},
                }
                (self.session_dir / "session.json").write_text(json.dumps(session))
                environment = {
                    **os.environ,
                    **self.env,
                    "KOGEN_SHAPING_ROUTE": session_values["route"],
                    "KOGEN_SHAPING_LAUNCH_ID": f"launch-{label}",
                }
                completed = subprocess.run(
                    [sys.executable, str(RELAY), "stop-output"], input=payload,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, check=True,
                )
                self.assertEqual(payload, completed.stdout)
                self.assertFalse(receipt_path.exists())

        self._write_session("optimum", "codex")
        route_mismatch_env = {
            **os.environ, **self.env,
            "KOGEN_SHAPING_ROUTE": "some-other-route",
            "KOGEN_SHAPING_LAUNCH_ID": "launch-route-mismatch",
        }
        mismatched = subprocess.run(
            [sys.executable, str(RELAY), "stop-output"], input=payload,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=route_mismatch_env, check=True,
        )
        self.assertEqual(payload, mismatched.stdout)
        self.assertFalse(receipt_path.exists())


if __name__ == "__main__":
    unittest.main()
