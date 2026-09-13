#!/usr/bin/env python3
"""Offline orchestration rehearsal for the public shaping evaluation driver.

This keeps the driver intact: only its process, clock, session directory and
fixture-preflight boundaries are faked.  The rollout files use the native JSONL
event shapes consumed by ``exact_root_rollout`` and ``user_turn_terminal``.
"""
import contextlib
import io
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
DRIVER_PATH = HERE / "driver.py"


def fake_parser_stdout(contents):
    """Only focused failure controls fake parser output; the composed run does not."""
    try:
        return json.dumps(json.loads(contents)).encode()
    except (TypeError, json.JSONDecodeError):
        return b'{"id":"parser-preflight"}'


class Clock:
    """Deterministic wall/monotonic clocks with independent wall jumps."""
    def __init__(self): self.wall = 0; self.mono = 0
    def time(self): self.wall += 1; return self.wall
    def monotonic(self): self.mono += 1; return self.mono
    def sleep(self, seconds): self.mono += max(1, seconds)
    def adjust_wall(self, seconds): self.wall += seconds


class Child:
    _next_pid = 41000
    def __init__(self, on_start=None, pid=None):
        self.returncode = None; self.on_start = on_start
        self.pid = pid if pid is not None else Child._next_pid
        Child._next_pid += 1
    def poll(self):
        if self.returncode is None and self.on_start is not None:
            self.returncode = self.on_start()
        return self.returncode
    def wait(self, timeout=None): self.returncode = 0; return 0
    def terminate(self): self.returncode = -15
    def kill(self): self.returncode = -9


class DriverRehearsalTest(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        self.temp = tempfile.TemporaryDirectory(prefix="kogen-driver-rehearsal-")
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime"; self.runtime.mkdir()
        self.sessions = self.root / "sessions"; self.sessions.mkdir()
        old_runtime = os.environ.get("KOGEN_SHAPING_EVALUATION_RUNTIME")
        os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = str(self.runtime)
        spec = importlib.util.spec_from_file_location("rehearsal_driver", DRIVER_PATH)
        self.driver = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.driver)
        self.driver.SESSION_ROOT = self.sessions
        if old_runtime is None: self.addCleanup(os.environ.pop, "KOGEN_SHAPING_EVALUATION_RUNTIME")
        else: self.addCleanup(os.environ.__setitem__, "KOGEN_SHAPING_EVALUATION_RUNTIME", old_runtime)

    def tearDown(self): self.temp.cleanup()

    def fixture(self, name, slug, intent_id="draft-identity"):
        fixture = self.root / name; fixture.mkdir(parents=True, exist_ok=True)
        (fixture / "README.md").write_text(
            "# Fixture\n\n## Current user request\n\n" + self.driver.current_request(name) + "\n"
        )
        for relative in ("app/csv", "test/csv"):
            path = fixture / relative; path.mkdir(parents=True); (path / "source.txt").write_text("source\n")
        draft = fixture / ".kogen/intents/drafts" / slug
        draft.mkdir(parents=True)
        intent = {"id": intent_id, "slug": slug, "title": "Rehearsal Draft", "status": "draft",
            "shaped_against": {"branch": "main", "head": "frozen-head"},
            "shaping": {"harness": "codex", "model": "fake-model", "effort": "low", "started": "original-visit"},
            "shaping_continuations": [], "may_change_guarded_paths": ["app/**", "test/**"]}
        if "csv-flawed" in name:
            intent["description"] = "Observed BOM discrepancy; invalid-row and replacement choices remain open"
        elif "booking-flawed" in name:
            intent["description"] = "Historical .tmp/calendar-run-17/connection.json is missing; audience choice remains open"
        elif "csv-continuation" in name:
            intent["description"] = "Invalid-row and output replacement questions remain open"
        # JSON is valid YAML.  The composed suite replaces selected cases with
        # block and flow-map forms, so the real parser reaches every supported
        # Draft form before integrity and DraftAudit consume the final bundle.
        (draft / "intent.yaml").write_text(json.dumps(intent, indent=2) + "\n")
        (draft / "scenarios.yaml").write_text(json.dumps([{"id": "reviewable-outcome", "given": "a starting actor",
            "when": "they use the feature", "then": "a usable result", "wrong_result": "an unusable result",
            "evidence": "fixture evidence", "verified_by": ["check"]}], indent=2) + "\n")
        (draft / "questions.md").write_text("# Questions\n")
        files = self.driver.csv_files(continuation=True) if name.endswith("csv-continuation") else \
            self.driver.csv_files() if name.endswith("csv-flawed") else \
            self.driver.csv_files(True) if name.endswith("csv-complete") else \
            self.driver.booking_files() if name.endswith("booking-flawed") else self.driver.booking_files(True)
        for relative, content in files.items():
            path = fixture / relative; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content if isinstance(content, bytes) else content.encode())
        return fixture

    def rollout(self, fixture, root_id, *, malformed=False, bad_json=False):
        path = self.sessions / f"rollout-{root_id}.jsonl"
        events = [
            {"type":"session_meta", "payload":{"id":root_id,"cwd":str(fixture),"source":{}}},
            {"type":"turn_context", "payload":{"turn_id":"startup","model":"fake-model","effort":"low"}},
            {"type":"response_item", "payload":{"type":"message","role":"assistant","content":[{"text":"Observed BOM discrepancy and missing .tmp/calendar-run-17/connection.json"}]}},
            {"type":"event_msg", "payload":{"type":"task_complete","turn_id":"startup"}},
        ]
        if malformed:
            events.append({"type":"response_item", "payload":{"type":"message","role":"user","content":[{"text":self.driver.transport_message("first")}]}})
        path.write_text("".join(json.dumps(item) + "\n" for item in events))
        if bad_json:
            with path.open("a") as handle: handle.write("{not-json}\n")
        return path

    def run_drive(self, case, slug, messages, triggers, *, continuation=False, missing_draft=False, malformed=False, bad_json=False, no_rollout=False, cleanup_fails=False, missing_evidence=False, incomplete_turn=False, startup_delay=0):
        fixture = self.fixture(case + "-" + slug, slug)
        if missing_draft:
            shutil.rmtree(fixture / ".kogen/intents/drafts" / slug)
        rollout = self.sessions / f"rollout-root-{case}-{slug}.jsonl"
        clock = Clock(); launches = []
        self.last_clock = clock

        def append_turn(text):
            turn = f"turn-{len(launches)}"
            with rollout.open("a") as handle:
                handle.write(json.dumps({"type":"turn_context","payload":{"turn_id":turn,"model":"fake-model","effort":"low"}}) + "\n")
                handle.write(json.dumps({"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":text}],"internal_chat_message_metadata_passthrough":{"turn_id":turn}}}) + "\n")
                assistant_text = ("Observed missing .tmp/calendar-run-17/connection.json for the proposed organizer"
                                  if case == "booking-flawed" else "Observed BOM discrepancy")
                handle.write(json.dumps({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":assistant_text}]}}) + "\n")
                handle.write(json.dumps({"type":"event_msg","payload":{"type":"task_complete","turn_id":turn}}) + "\n")
            if incomplete_turn:
                rollout.write_text("".join(rollout.read_text().splitlines(keepends=True)[:-1]))
            if missing_evidence:
                (fixture / "README.md").unlink(missing_ok=True)
            if missing_draft: return
            draft = fixture / ".kogen/intents/drafts" / slug / "intent.yaml"
            saved = json.loads(draft.read_text())
            if case == "csv-continuation":
                saved["description"] = ("invalid selected rows are all-or-nothing; output replacement remains unanswered") if len(launches) == 2 else "transaction recovery settled"
            elif case == "booking-flawed":
                saved["description"] = ("historical .tmp/calendar-run-17/connection.json is missing; reachability choice remains open"
                                        if len(launches) == 2 else "saved complete Draft")
            else:
                saved["description"] = "BOM invalid" if len(launches) == 2 else "saved complete Draft"
            draft.write_text(json.dumps(saved))

        def popen(argv, **_kwargs):
            launches.append(argv)
            # Only resumes submit a scripted reply.  The public startup is already
            # represented by the native startup completion above.
            if "resume_transport.exp" in argv[1] and not malformed:
                append_turn(Path(argv[4]).read_text())
            elif "shape_transport.exp" in argv[1] and not no_rollout:
                self.rollout(fixture, f"root-{case}-{slug}", malformed=malformed, bad_json=bad_json)
                if startup_delay:
                    lines = rollout.read_text().splitlines(keepends=True)
                    completion = lines.pop(3)
                    rollout.write_text("".join(lines))
                    def finish_startup():
                        if clock.mono >= startup_delay:
                            with rollout.open("a") as handle: handle.write(completion)
                            child.on_start = None
                        return None
                    child = Child(on_start=finish_startup)
                    return child
            return Child()

        class Result:
            returncode = 0; stdout = ""; stderr = ""
        def run(argv, **_kwargs):
            result = Result()
            if argv and argv[0] == "elixir":
                result.stdout = fake_parser_stdout(_kwargs["input"])
            return result
        def reaper(_fixture, _frozen=None):
            return {"roots":[],"before":[],"actions":[],"remaining_pids":[],"all_reaped":not cleanup_fails}
        profiles = ({"root":("fake-model","low"),"scout":("fake-model","low"),"worker":("fake-model","low"),"expert":("fake-model","low")}, {"normalized":{}})
        with patch.object(self.driver.time, "time", clock.time), patch.object(self.driver.time, "monotonic", clock.monotonic), patch.object(self.driver.time, "sleep", clock.sleep), \
             patch.object(self.driver.subprocess, "Popen", popen), patch.object(self.driver.subprocess, "run", run), \
             patch.object(self.driver, "configured_profiles", lambda _fixture: profiles), \
             patch.object(self.driver, "source_snapshot", lambda _fixture: {"README.md":"fixture"}), \
             patch.object(self.driver, "write_csv_probe_result", lambda _fixture, out: (out / "csv-probe-result.json").write_text("{}\n")), \
             patch.object(self.driver, "write_booking_setup_observation", lambda _fixture, out: (out / "booking-setup-observation.json").write_text("{}\n")), \
             patch.object(self.driver, "owned_process_tree", lambda _fixture: []), \
             patch.object(self.driver, "reap_owned_cli", reaper):
            run_case = case if not (self.runtime / "runs" / case).exists() else case + "-" + slug
            receipt = self.driver.drive(run_case, fixture, slug, messages, triggers, continuation)
        return receipt, launches

    def test_real_drive_rehearses_startup_product_turns_clarification_and_continuation(self):
        booking_reachability_trigger = self.driver.booking_reachability_trigger
        self.assertFalse(booking_reachability_trigger("Observed BOM discrepancy", None))
        self.assertTrue(booking_reachability_trigger(
            "Observed missing .tmp/calendar-run-17/connection.json for the proposed organizer", None))
        cases = (
            ("csv-flawed", "eval-csv-flawed", ["clarification"], [lambda text, root: "bom" in text.lower() and self.driver.rollout_contains(root, "BOM")]),
            ("csv-complete", "eval-csv-complete", [], []),
            ("booking-flawed", "eval-booking-flawed", ["clarification"],
             [booking_reachability_trigger]),
            ("booking-complete", "eval-booking-complete", [], []),
            ("csv-continuation", "eval-csv-flawed", ["partial", "final"], [lambda _text, _root: True, lambda _text, _root: True]),
        )
        for case, slug, messages, triggers in cases:
            receipt, launches = self.run_drive(case, slug, messages, triggers, continuation=case == "csv-continuation")
            self.assertEqual("completed", receipt["outcome"], receipt)
            self.assertEqual(len(messages), len(receipt["terminal_events"]))
            sent=json.loads((self.runtime / "runs" / case / "messages.json").read_text())
            self.assertEqual(messages, [entry["text"] for entry in sent])
            self.assertEqual([self.driver.transport_message(message) for message in messages], [entry["submitted_text"] for entry in sent])
            self.assertTrue(all("Reply channel:" in entry["submitted_text"] for entry in sent))
            self.assertEqual(1 + len(messages), len(launches))
            self.assertEqual("draft-identity", json.loads((self.runtime / "runs" / case / "draft-state.json").read_text())["intent_id"])
        continuation = json.loads((self.runtime / "runs/csv-continuation/draft-state.json").read_text())
        self.assertEqual("draft-identity", continuation["intent_id"])
        continuation_receipt = json.loads((self.runtime / "runs/csv-continuation/receipt.json").read_text())
        self.assertEqual(2, continuation_receipt["scripted_replies"])
        self.assertEqual(2, len(continuation_receipt["terminal_turn_bindings"]))
        self.assertEqual(2, len(set(continuation_receipt["terminal_turn_bindings"])))
        self.assertTrue((self.runtime / "runs/csv-continuation/drafts-by-turn/0/questions.md").is_file())

    def test_readiness_controls_preserve_unprompted_representation_and_consequential_choices(self):
        """Regression inputs stay discriminating; only independent Review grades meaning."""
        self.driver.write_semantic_counterexamples()
        saved = self.runtime / "semantic-counterexamples.json"
        self.assertEqual(saved.read_bytes(), (HERE / saved.name).read_bytes())
        controls = {item["id"]: item for item in json.loads(saved.read_text())}
        for control_id in ("booking-routine-serialization-blocker",
                           "serialization-consequential-compatibility"):
            self.assertTrue(controls[control_id]["acceptable_contrast"])
            self.assertTrue(controls[control_id]["review_check"])
        self.assertIn("Counterfactual", controls["serialization-consequential-compatibility"]["scope"])
        # Exercise actual fixture selection, not a copied brief.  Do not make
        # the complete case pass by supplying a serialization answer or rubric.
        complete = self.driver.booking_files(complete=True)
        facts = json.loads(complete["evidence/facts.json"])
        source = json.loads((HERE / "compact-fixtures-v2/facts.json").read_text())
        self.assertEqual(set(facts), {"feature", "data", "failure", "setup", "actors", "source_ownership", "output_contract"})
        for key in ("feature", "data", "failure", "setup"):
            self.assertEqual(facts[key], source["calendar"][key])
        model_input = "\n".join(value.decode() if isinstance(value, bytes) else value
                                for value in complete.values()) + self.driver.BOOKING_COMPLETE
        for item in controls.values():
            self.assertNotIn(item["draft_excerpt"], model_input)
        self.assertNotIn("requires TSV", model_input)
        # The paired real continuation still withholds data-loss/recovery
        # choices. Ordinary serialization discretion cannot auto-answer these.
        partial = json.loads(self.driver.csv_files(continuation=True)["evidence/facts.json"])
        self.assertNotIn("invalid_policy", partial)
        self.assertNotIn("replacement_policy", partial)
        self.assertEqual(self.driver.CSV_CONT_PARTIAL, source["csv"]["continuation_partial"])
        self.assertEqual(self.driver.CSV_CONT_FINAL, source["csv"]["continuation_full"])

    def test_terminal_requires_nonblank_native_turn_binding(self):
        path = self.sessions / "rollout-binding.jsonl"
        base = self.rollout(self.root, "binding")
        with base.open("a") as handle:
            handle.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"text": "bound"}], "internal_chat_message_metadata_passthrough": {"turn_id": " "}}}) + "\n")
            handle.write(json.dumps({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": " "}}) + "\n")
        self.assertEqual((None, False), self.driver.user_turn_terminal(path, "bound"))

    def test_monotonic_deadline_survives_wall_clock_adjustment(self):
        clock = Clock()
        with patch.object(self.driver.time, "time", clock.time), patch.object(self.driver.time, "monotonic", clock.monotonic):
            deadline = self.driver.monotonic_now() + 5
            clock.adjust_wall(10_000)
            self.assertLess(self.driver.monotonic_now(), deadline)
            clock.adjust_wall(-20_000)
            self.assertLess(self.driver.monotonic_now(), deadline)

    def test_missing_or_late_initial_request_cannot_reach_public_dispatch(self):
        fixture = self.fixture("csv-complete-missing-request", "eval-csv-complete")
        (fixture / "README.md").write_text("# Neutral fixture\n")
        launched = []
        profiles = ({"root": ("fake-model", "low")}, {"normalized": {}})
        result = type("Result", (), {"stdout": "", "returncode": 0})()
        def unexpected_launch(*args, **kwargs):
            launched.append(args)
            raise AssertionError("public dispatch occurred without a frozen request")
        with patch.object(self.driver, "configured_profiles", lambda _fixture: profiles), \
             patch.object(self.driver, "source_snapshot", lambda _fixture: {"README.md": "neutral"}), \
             patch.object(self.driver.subprocess, "run", lambda *args, **kwargs: result), \
             patch.object(self.driver.subprocess, "Popen", unexpected_launch):
            with self.assertRaisesRegex(RuntimeError, "current user request is missing before public dispatch"):
                self.driver.drive("csv-complete", fixture, "eval-csv-complete", [], [])
        self.assertEqual([], launched)

        # Adding the request afterward cannot retroactively make a dispatch valid.
        (fixture / "README.md").write_text(self.driver.current_request("csv-complete") + "\n")
        self.assertFalse((self.runtime / "runs/csv-complete/input-delivery.json").exists())

    def test_deliberate_transport_term_does_not_override_a_completed_clean_case(self):
        receipt = {
            "transport_exit": 143,
            "scripted_replies": 1,
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
        receipt["outcome"] = "infrastructure-error"
        self.assertFalse(self.driver.case_succeeded(receipt))
        receipt["outcome"] = "completed"
        receipt["cleanup"][0]["all_reaped"] = False
        self.assertFalse(self.driver.case_succeeded(receipt))

    def test_startup_uses_remaining_case_budget_without_reset_or_retry(self):
        receipt, launches = self.run_drive("csv-complete", "slow-start", ["first"], [], startup_delay=200)
        self.assertIsNone(receipt["failure"])
        self.assertEqual(2, len(launches))
        receipt, launches = self.run_drive("csv-complete", "budget-used", ["first"], [],
                                          startup_delay=500, missing_draft=True)
        self.assertEqual("TimeoutError", receipt["failure"]["type"], receipt["failure"])
        self.assertIn("initial request turn did not save Draft", receipt["failure"]["message"])
        self.assertLess(self.last_clock.mono, self.driver.MAX_SECONDS + 30)
        self.assertEqual(1, len(launches))
        receipt, launches = self.run_drive("csv-complete", "startup-expired", ["first"], [],
                                          startup_delay=700)
        self.assertEqual("native startup turn", receipt["failure"]["message"])
        self.assertEqual(1, len(launches))
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_failures_keep_specific_reason_and_do_not_make_a_manifest(self):
        receipt, _ = self.run_drive("csv-complete", "missing-rollout", ["first"], [], no_rollout=True)
        self.assertEqual("native startup turn", receipt["failure"]["message"])
        receipt, _ = self.run_drive("csv-flawed", "eval", ["first"], [], missing_draft=True)
        self.assertEqual("TimeoutError", receipt["failure"]["type"])
        self.assertIn("did not save Draft", receipt["failure"]["message"])
        missing_run=self.runtime / "runs/csv-flawed"
        self.assertTrue((missing_run / "owned-session-metadata.json").is_file())
        self.assertTrue((missing_run / "owned-rollouts").is_dir())
        self.assertTrue((missing_run / "evidence").is_dir())
        self.assertTrue((missing_run / "fixture-source/README.md").is_file())
        self.assertTrue((missing_run / "source-after.json").is_file())
        self.assertEqual("draft-state", receipt["correlation"]["capture_error"]["stage"])
        self.assertEqual("infrastructure-error", receipt["outcome"])
        receipt, _ = self.run_drive("booking-flawed", "eval", ["first"], [], malformed=True)
        self.assertIn("malformed or uncorrelated", receipt["failure"]["message"])
        receipt, _ = self.run_drive("booking-complete", "eval-json", ["first"], [], malformed=True, bad_json=True)
        self.assertEqual("JSONDecodeError", receipt["failure"]["type"])
        self.assertIn("capture_error", receipt["correlation"])
        receipt, _ = self.run_drive("csv-complete", "eval", ["first", "second"], [lambda _text, _root: False])
        self.assertEqual("TriggerMismatch", receipt["failure"]["type"])
        receipt, _ = self.run_drive("booking-complete", "eval", ["first"], [], cleanup_fails=True)
        self.assertIn("descendants were not reaped", receipt["failure"]["message"])
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_capture_loss_and_incomplete_product_turn_retain_specific_failures(self):
        receipt, launches = self.run_drive("csv-missing-evidence", "eval", ["first"], [], missing_evidence=True)
        self.assertIn("evidence capture failed", receipt["failure"]["message"])
        self.assertIn("README.md", receipt["failure"]["message"])
        self.assertEqual(2, len(launches))
        self.assertTrue(receipt["cleanup"][-1]["all_reaped"])
        receipt, launches = self.run_drive("csv-timeout", "eval", ["first"], [], incomplete_turn=True)
        self.assertEqual("RuntimeError", receipt["failure"]["type"])
        self.assertIn("malformed or uncorrelated", receipt["failure"]["message"])
        self.assertEqual([], receipt["terminal_events"])
        self.assertTrue(receipt["cleanup"][-1]["all_reaped"])

    def test_suite_rejects_missing_capture_before_later_launches(self):
        calls=[]
        class Result:
            returncode=0; stdout="child claimed success"; stderr=""
        def run(argv, **kwargs):
            if argv and argv[0] == "elixir":
                result = Result(); result.stdout = fake_parser_stdout(kwargs["input"]); return result
            if argv[:3] == ["python3", "-B", str(DRIVER_PATH.resolve())]: calls.append(argv[-1])
            return Result()
        with patch.object(self.driver.subprocess, "run", run):
            self.assertEqual(1, self.driver.run_suite())
        self.assertEqual([], calls)
        failure=json.loads((self.runtime / "suite-failure.json").read_text())
        self.assertTrue(failure["message"])
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_parser_preflight_stops_all_case_dispatch_when_compiled_paths_are_unavailable(self):
        launches = []

        def run(argv, **_kwargs):
            launches.append(argv)
            raise AssertionError("a provider-case child must not start before parser preflight")

        with patch.object(self.driver.os, "environ", {}), patch.object(self.driver.subprocess, "run", run):
            self.assertEqual(1, self.driver.run_suite())

        failure = json.loads((self.runtime / "suite-failure.json").read_text())
        self.assertEqual("suite preflight", failure["case"])
        self.assertIn("parser dependency unavailable", failure["message"])
        self.assertEqual([], launches)
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_run_suite_dispatches_all_five_before_collection_and_reaps_after_child_failure(self):
        launches, polls, reaped, signals = [], [], [], []
        cases = ("csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation")

        def parser(argv, **kwargs):
            class Result:
                returncode = 0
                stdout = fake_parser_stdout(kwargs["input"])
                stderr = ""
            return Result()

        def popen(argv, **kwargs):
            case = argv[-1]
            launches.append((case, kwargs))
            # Only the three cases reached by collection settle. The later two
            # remain live until cancellation, modelling children blocked at the
            # shared suite barrier while preserving the parent dispatch order.
            class SuiteChild(Child):
                def poll(self):
                    if self.returncode is not None:
                        return self.returncode
                    if case in ("booking-complete", "csv-continuation"):
                        return None
                    polls.append(case)
                    if case == "booking-flawed":
                        kwargs["stdout"].write("fixture child failed after native startup\n")
                        kwargs["stdout"].flush()
                        self.returncode = 7
                    else:
                        self.returncode = 0
                    return self.returncode
            return SuiteChild()

        def reap(fixture, _before):
            reaped.append(fixture.name)
            if fixture.name == "booking-complete":
                raise RuntimeError("injected reaper cleanup failure")
            return {"roots": [], "before": [], "actions": [], "remaining_pids": [], "all_reaped": True}

        with patch.object(self.driver.subprocess, "run", parser), \
             patch.object(self.driver.subprocess, "Popen", popen), \
             patch.object(self.driver, "setup_continuation_seed", lambda: self.runtime / "continuation-seed"), \
             patch.object(self.driver, "write_semantic_counterexamples", lambda: (self.runtime / "semantic-counterexamples.json").write_text("{}\n")), \
             patch.object(self.driver, "required_case_capture", lambda _case: None), \
             patch.object(self.driver, "owned_process_tree", lambda _fixture: []), \
             patch.object(self.driver, "reap_owned_cli", reap), \
             patch.object(self.driver.os, "killpg", lambda pid, sig: signals.append((pid, sig))):
            self.assertEqual(1, self.driver.run_suite())

        self.assertEqual(list(cases), [case for case, _kwargs in launches])
        self.assertEqual(set(cases), {case for case, kwargs in launches if kwargs["start_new_session"] is True})
        self.assertEqual("csv-flawed", polls[0])
        self.assertEqual(5, len(launches), "collection began before all five independent children were dispatched")
        self.assertEqual(set(cases), set(reaped))
        self.assertTrue(signals, "pending child process groups were not cancelled")
        failure = json.loads((self.runtime / "suite-failure.json").read_text())
        # A cleanup problem stays additive: the original failing child remains
        # the suite cause and its retained output remains inspectable.
        self.assertEqual("booking-flawed", failure["case"])
        self.assertIn("child exited 7", failure["message"])
        self.assertEqual("booking-complete", failure["cleanup_errors"][0]["case"])
        self.assertIn("injected reaper cleanup failure", failure["cleanup_errors"][0]["message"])
        child_log = (self.runtime / "booking-flawed-output.log").read_text()
        self.assertIn("fixture child failed after native startup", child_log)
        self.assertFalse((self.runtime / "evidence-manifest.json").exists())

    def test_run_suite_real_children_overlap_at_the_actual_barrier_before_collection(self):
        """Five cheap OS children exercise the production file barrier, offline."""
        real_popen = self.driver.subprocess.Popen
        events = self.runtime / "barrier-events"
        child_script = r"""
import importlib.util, json, os, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location("barrier_driver", sys.argv[1])
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
case = sys.argv[2]
entered = time.monotonic()
driver.suite_barrier(case)
released = time.monotonic()
events = Path(os.environ["KOGEN_REHEARSAL_BARRIER_EVENTS"])
events.mkdir(exist_ok=True)
(events / (case + ".json")).write_text(json.dumps({"case": case, "entered": entered, "released": released, "ready_count": len(list((driver.RUNTIME / "barrier").glob("*.ready")))}))
"""
        captures, launches = [], []

        def popen(argv, **kwargs):
            case = argv[-1]
            launches.append((case, kwargs))
            env = {**kwargs["env"], "KOGEN_REHEARSAL_BARRIER_EVENTS": str(events)}
            return real_popen(
                ["python3", "-B", "-c", child_script, str(DRIVER_PATH), case],
                env=env,
                stdout=kwargs["stdout"],
                stderr=kwargs["stderr"],
                text=True,
                start_new_session=True,
            )

        def capture(case):
            captures.append(case)
            ready = list((self.runtime / "barrier").glob("*.ready"))
            self.assertEqual(5, len(ready), "a child was collected before every child reached the production barrier")

        with patch.object(self.driver, "preflight_yaml_parser", lambda: None), \
             patch.object(self.driver, "setup_continuation_seed", lambda: self.runtime / "continuation-seed"), \
             patch.object(self.driver, "write_semantic_counterexamples", lambda: (self.runtime / "semantic-counterexamples.json").write_text("{}\n")), \
             patch.object(self.driver, "required_case_capture", capture), \
             patch.object(self.driver, "write_manifest", lambda: {"offline": True}), \
             patch.object(self.driver.subprocess, "Popen", popen):
            self.assertEqual(0, self.driver.run_suite())

        expected = ["csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation"]
        self.assertEqual(expected, [case for case, _kwargs in launches])
        self.assertEqual(set(expected), set(captures))
        records = [json.loads(path.read_text()) for path in events.glob("*.json")]
        self.assertEqual(5, len(records))
        self.assertTrue(all(record["ready_count"] == 5 for record in records))
        self.assertLessEqual(max(record["entered"] for record in records), min(record["released"] for record in records))
        self.assertTrue(all(kwargs["start_new_session"] is True for _case, kwargs in launches))
        self.assertFalse((self.runtime / "suite-failure.json").exists())


    def test_cleanup_records_filesystem_failure_and_success(self):
        fixture = self.root / "cleanup-fixture"; fixture.mkdir()
        run = self.runtime / "runs/cleanup"; (run / "fixture-source").mkdir(parents=True)
        for name in ("receipt.json", "source-baseline.json", "source-after.json"):
            (run / name).write_text("{}\n")
        (run / "fixture-source/README.md").write_text("fixture\n")
        with patch.object(self.driver.shutil, "rmtree", side_effect=OSError("read-only fixture")):
            failed = self.driver.cleanup_fixture(fixture, "cleanup")
        self.assertFalse(failed["removed"])
        self.assertIn("fixture cleanup failed", failed["reason"])
        self.assertTrue((run / "fixture-cleanup.json").is_file())
        receipt={"outcome":"completed", "failure":None}
        with patch.object(self.driver.shutil, "rmtree", side_effect=OSError("read-only fixture")):
            self.driver.require_cleanup(fixture, "cleanup", receipt)
        self.assertEqual("infrastructure-error", receipt["outcome"])
        self.assertEqual("CleanupFailure", receipt["failure"]["type"])

        succeeded = self.driver.cleanup_fixture(fixture, "cleanup")
        self.assertTrue(succeeded["removed"])
        self.assertFalse(fixture.exists())

    def test_composed_suite_uses_main_routes_and_real_drive_before_manifest(self):
        """The suite reaches the real parser and both final evidence consumers."""
        self.driver.PROJECT = self.root.resolve()
        clock = Clock(); launches = []; continuation_fixtures = set(); rollouts = {}
        real_run = self.driver.subprocess.run
        real_popen = self.driver.subprocess.Popen

        def setup(case, _files):
            slug = {"csv-flawed":"eval-csv-flawed", "csv-continuation":"eval-csv-seed", "csv-complete":"eval-csv-complete",
                    "booking-flawed":"eval-booking-flawed", "booking-complete":"eval-booking-complete"}[case]
            fixture = self.fixture(str(self.runtime / case), "temporary-seed" if case == "csv-continuation" else slug, "original-csv" if case == "csv-flawed" else f"id-{case}")
            (fixture / "README.md").write_text("# Fixture\n\n## Current user request\n\n" + self.driver.current_request(case) + "\n")
            intent = fixture / ".kogen/intents/drafts" / slug / "intent.yaml"
            if case == "csv-complete":
                intent.write_text("id: id-csv-complete\nslug: eval-csv-complete\ntitle: Rehearsal Draft\nstatus: draft\nshaped_against: {branch: main, head: frozen-head}\nshaping: {harness: codex, model: fake-model, effort: low, started: original-visit}\nshaping_continuations: []\nmay_change_guarded_paths: [app/**, test/**]\n")
            elif case == "booking-flawed":
                intent.write_text("{id: id-booking-flawed, slug: eval-booking-flawed, title: Rehearsal Draft, status: draft, description: historical .tmp/calendar-run-17/connection.json is missing and the audience choice remains open, shaped_against: {branch: main, head: frozen-head}, shaping: {harness: codex, model: fake-model, effort: low, started: original-visit}, shaping_continuations: [], may_change_guarded_paths: [app/**, test/**]}\n")
            return fixture

        def popen(argv, **_kwargs):
            if argv[:3] == ["python3", "-B", str(DRIVER_PATH.resolve())]:
                case = argv[3]
                def invoke_case():
                    with patch.object(sys, "argv", ["driver.py", case]):
                        result = self.driver.main()
                    if getattr(self, "corrupt_first_capture", False) and case == "csv-flawed":
                        state = self.runtime / "runs/csv-flawed/draft-state.json"
                        state.write_text(json.dumps({"intent_id": None, "baseline": {"branch": None, "head": None},
                                                     "visit_id": None, "unapproved": True}))
                    return result
                return Child(invoke_case)
            if not argv or argv[0] != "expect":
                return real_popen(argv, **_kwargs)
            fixture = Path(argv[2])
            if Path(argv[1]).name == "shape_transport.exp":
                continuation_fixtures.update([fixture] if argv[5] else [])
                rollouts[str(fixture)] = self.rollout(fixture, f"root-{fixture.name}-{len(launches)}")
            else:
                rollout = rollouts[str(fixture)]
                prompt = Path(argv[4]).read_text(); turn = f"turn-{len(launches)}"
                with rollout.open("a") as handle:
                    handle.write(json.dumps({"type":"turn_context","payload":{"turn_id":turn,"model":"fake-model","effort":"low"}})+"\n")
                    handle.write(json.dumps({"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":prompt}],"internal_chat_message_metadata_passthrough":{"turn_id":turn}}})+"\n")
                    handle.write(json.dumps({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"Observed BOM and missing .tmp/calendar-run-17/connection.json"}]}})+"\n")
                    handle.write(json.dumps({"type":"event_msg","payload":{"type":"task_complete","turn_id":turn}})+"\n")
                slug = "eval-csv-seed" if fixture.name == "csv-continuation" else ("eval-csv-flawed" if fixture.name == "csv-flawed" else f"eval-{fixture.name}")
                draft = fixture / ".kogen/intents/drafts" / slug / "intent.yaml"
                if fixture.name == "csv-continuation":
                    saved = json.loads(draft.read_text())
                    saved["shaping_continuations"] = [{"harness": "codex", "model": "fake-model", "effort": "low",
                                                       "started":"fresh-continuation", "checkout":saved["shaped_against"]}]
                    draft.write_text(json.dumps(saved))
                existing_user_turns = sum(1 for line in rollout.read_text().splitlines() if '"role": "user"' in line)
                if fixture.name == "csv-continuation" and existing_user_turns == 1:
                    saved = json.loads(draft.read_text())
                    saved["description"] = "invalid selected rows are all-or-nothing; output replacement remains unanswered"
                    draft.write_text(json.dumps(saved))
                elif fixture.name == "csv-continuation" and existing_user_turns >= 2:
                    saved = json.loads(draft.read_text())
                    saved["description"] = "transaction recovery settled"
                    draft.write_text(json.dumps(saved))
                question = ("What should happen to the existing output when replacement work succeeds or fails?\n"
                            if fixture.name == "csv-continuation" else
                            "BOM invalid missing absent .tmp/calendar-run-17/connection.json\n")
                (draft.parent / "questions.md").write_text(question)
            launches.append(argv); return Child()

        class Result:
            def __init__(self, returncode=0): self.returncode=returncode; self.stdout=""; self.stderr=""
        def run(argv, **_kwargs):
            if argv[:3] == ["git", "rev-parse", "HEAD"]:
                result = Result(); result.stdout = "frozen-head\n"; return result
            if argv[:3] == ["python3", "-B", str(DRIVER_PATH.resolve())]:
                with patch.object(sys, "argv", ["driver.py", argv[3]]):
                    result = Result(self.driver.main())
                if getattr(self, "corrupt_first_capture", False) and argv[3] == "csv-flawed":
                    state = self.runtime / "runs/csv-flawed/draft-state.json"
                    state.write_text(json.dumps({"intent_id": None, "baseline": {"branch": None, "head": None},
                                                 "visit_id": None, "unapproved": True}))
                return result
            if argv and argv[0] == "elixir":
                return real_run(argv, **_kwargs)
            if argv[:2] == ["python3", "-B"]:
                return real_run(argv, **_kwargs)
            return Result()
        profiles = ({"root":("fake-model","low"),"scout":("fake-model","low"),"worker":("fake-model","low"),"expert":("fake-model","low")}, {"normalized":{}})
        with patch.object(self.driver.time, "time", clock.time), patch.object(self.driver.time, "monotonic", clock.monotonic), patch.object(self.driver.time, "sleep", clock.sleep), \
             patch.object(self.driver.subprocess, "Popen", popen), patch.object(self.driver.subprocess, "run", run), \
             patch.object(self.driver, "setup_fixture", setup), patch.object(self.driver, "configured_profiles", lambda _fixture: profiles), \
             patch.object(self.driver, "source_snapshot", lambda _fixture: {"README.md":"fixture"}), \
            patch.object(self.driver, "owned_process_tree", lambda _fixture: []), \
            patch.object(self.driver, "suite_barrier", lambda _case: None), \
            patch.object(self.driver, "reap_owned_cli", lambda *_args: {"roots":[],"before":[],"actions":[],"remaining_pids":[],"all_reaped":True}):
            status = self.driver.run_suite()
        if getattr(self, "corrupt_first_capture", False):
            self.assertEqual(1, status)
            failure = json.loads((self.runtime / "suite-failure.json").read_text())
            self.assertIn("captured provenance differs from original Draft", failure["message"])
            self.assertEqual(5, sum(Path(argv[1]).name == "shape_transport.exp" for argv in launches))
            self.assertFalse((self.runtime / "evidence-manifest.json").exists())
            self.assertNotIn("KOGEN_TARGET_EVIDENCE_MANIFEST\t", self.output.getvalue())
            return
        if status:
            self.fail((self.runtime / "suite-failure.json").read_text())
        self.assertTrue((self.runtime / "evidence-manifest.json").is_file())
        state = json.loads((self.runtime / "runs/csv-continuation/draft-state.json").read_text())
        self.assertEqual("01990000-0000-7000-8000-00000000c501", state["intent_id"])
        self.assertEqual("csv-continuation", next(iter(continuation_fixtures)).name)
        self.assertEqual(5, sum(1 for argv in launches if Path(argv[1]).name == "shape_transport.exp"))
        cases = ["csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation"]
        public = [argv for argv in launches if Path(argv[1]).name == "shape_transport.exp"]
        self.assertEqual(["csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation"], [Path(argv[2]).name for argv in public])
        root_ids=[]
        for case, count in zip(cases, [1, 0, 1, 0, 2]):
            run = self.runtime / "runs" / case
            receipt = json.loads((run / "receipt.json").read_text())
            messages = json.loads((run / "messages.json").read_text())
            self.assertEqual(count, len(messages))
            self.assertEqual(count, receipt["scripted_replies"])
            self.assertEqual(count, len(receipt["terminal_events"]))
            self.assertEqual(count, len({event["turn_id"] for event in receipt["terminal_events"]}))
            if case == "csv-continuation":
                self.assertEqual(2, len(messages))
                self.assertEqual(2, len(receipt["terminal_turn_bindings"]))
                self.assertEqual(2, len(set(receipt["terminal_turn_bindings"])))
                self.assertTrue((run / "drafts-by-turn/0/questions.md").is_file())
            self.assertTrue(all(isinstance(event["root_rollout"], str) for event in receipt["terminal_events"]))
            root_ids.append(receipt["correlation"]["roots"][0])
        self.assertEqual(5, len(set(root_ids)))
        first = json.loads((self.runtime / "runs/csv-flawed/draft/intent.yaml").read_text())
        seed = json.loads((self.runtime / "continuation-seed/intent.yaml").read_text())
        partial = json.loads((self.runtime / "runs/csv-continuation/drafts-by-turn/0/intent.yaml").read_text())
        continued = json.loads((self.runtime / "runs/csv-continuation/draft/intent.yaml").read_text())
        self.assertNotEqual(first["id"], seed["id"])
        for document in (partial, continued):
            for key in ("id", "slug", "shaping", "shaped_against"):
                self.assertEqual(seed[key], document[key])
            self.assertEqual(seed["shaping_continuations"] + document["shaping_continuations"][-1:], document["shaping_continuations"])
        self.assertEqual(partial["shaping_continuations"], continued["shaping_continuations"])
        self.assertEqual([], first["shaping_continuations"])
        self.assertEqual(1, len(continued["shaping_continuations"]))
        self.assertEqual("fresh-continuation", state["visit_id"])
        self.assertEqual(seed["shaped_against"], state["baseline"])
        for case in cases[:-1]:
            self.assertFalse((self.runtime / case).exists())
        manifest = json.loads((self.runtime / "evidence-manifest.json").read_text())
        manifested_paths = [entry["path"] for entry in manifest["required_evidence"]]
        manifest_case_order = [
            case for path in manifested_paths for case in cases
            if path.endswith(f"/runs/{case}/review-receipt.json")
        ]
        self.assertEqual(cases, manifest_case_order)
        self.assertFalse(any("/owned-rollouts/" in path or "/private-raw-rollouts/" in path for path in manifested_paths))
        self.assertFalse(any(path.endswith(("/receipt.json", "/transport.log", "/pty.log")) or "/resume-" in path and path.endswith("-pty.log") for path in manifested_paths))
        for case in cases:
            self.assertTrue(any(path.endswith(f"/runs/{case}/review-receipt.json") for path in manifested_paths))
            self.assertTrue((self.runtime / f"runs/{case}/receipt.json").is_file())
            self.assertTrue((self.runtime / f"runs/{case}/owned-rollouts").is_dir())
        for partial_file in (self.runtime / "runs/csv-continuation/drafts-by-turn/0").rglob("*"):
            if partial_file.is_file():
                self.assertIn(str(partial_file.relative_to(self.root)), manifested_paths)
        self.assertIn("runtime/continuation-seed-metadata.json", manifested_paths)
        self.assertIn("runtime/semantic-counterexamples.json", manifested_paths)
        self.assertEqual((self.runtime / "semantic-counterexamples.json").read_bytes(),
                         (HERE / "semantic-counterexamples.json").read_bytes())

        for entry in manifest["required_evidence"]:
            self.assertEqual(entry["sha256"], hashlib.sha256((self.root / entry["path"]).read_bytes()).hexdigest())
        # These are the same final consumers used after the live driver.  Do
        # not replace them with fixture-local schema checks: integrity verifies
        # native events and hashes, while DraftAudit parses the retained YAML.
        integrity = importlib.util.spec_from_file_location("rehearsal_integrity", HERE / "integrity.py")
        integrity_module = importlib.util.module_from_spec(integrity); integrity.loader.exec_module(integrity_module)
        integrity_module.validate_manifest(self.root, self.runtime / "evidence-manifest.json")
        code_paths = json.loads(os.environ["KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS"])
        audit = "Code.require_file({}, {}); Kogen.ShapingDraftAudit.audit!({})".format(
            json.dumps(str(HERE / "draft_audit.ex")), json.dumps(str(HERE)), json.dumps(str(self.runtime)))
        result = real_run(["elixir", *sum((["-pa", path] for path in code_paths), []), "-e", audit],
                          capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        # Rehash mutated state so these negatives reach provenance validators,
        # rather than claiming a manifest hash failure as proof.
        state_path = self.runtime / "runs/csv-complete/draft-state.json"
        original_state = state_path.read_bytes()
        manifest_path = self.runtime / "evidence-manifest.json"
        for key, value in (("intent_id", None), ("baseline", {"branch": "main", "head": "altered"}),
                           ("visit_id", "altered"), ("unapproved", False)):
            changed = json.loads(original_state); changed[key] = value
            state_path.write_text(json.dumps(changed))
            manifest = json.loads(manifest_path.read_text())
            for entry in manifest["required_evidence"]:
                entry["sha256"] = hashlib.sha256((self.root / entry["path"]).read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest))
            if key in ("intent_id", "unapproved"):
                with self.assertRaisesRegex(ValueError, "draft provenance state missing"):
                    integrity_module.validate_manifest(self.root, manifest_path)
            else:
                integrity_module.validate_manifest(self.root, manifest_path)
            invalid = real_run(["elixir", *sum((["-pa", path] for path in code_paths), []), "-e", audit],
                               capture_output=True, text=True, timeout=30)
            self.assertNotEqual(0, invalid.returncode)
            self.assertIn("captured state differs", invalid.stdout + invalid.stderr)
        state_path.write_bytes(original_state)



    def test_valid_yaml_with_null_first_capture_stops_real_suite_before_later_dispatch(self):
        self.corrupt_first_capture = True
        self.test_composed_suite_uses_main_routes_and_real_drive_before_manifest()

    def test_main_routes_each_public_case_without_launching_a_provider(self):
        routed = []; cleaned = []
        valid = {"transport_exit":0,"scripted_replies":0,"git_status":{"baseline_unchanged":True,"draft_exists":True},
                 "source_identity":{"unchanged":True},"outcome":"completed",
                 "correlation":{"exactly_one_root":True,"all_owned_terminal":True,"all_profiles_match":True},
                 "cleanup":[{"all_reaped":True}]}
        continuation_fixture = self.runtime / "csv-continuation"
        continuation_draft = continuation_fixture / ".kogen/intents/drafts/eval-csv-seed"
        continuation_draft.mkdir(parents=True)
        (self.runtime / "continuation-seed").mkdir()
        def setup(case, _files): routed.append(("setup", case)); return self.root / case
        def drive(case, fixture, slug, messages, triggers, continuation=False):
            routed.append(("drive", case, fixture, slug, len(messages), continuation)); return valid
        with patch.object(self.driver, "setup_fixture", setup), patch.object(self.driver, "setup_continuation_seed", lambda: self.runtime / "continuation-seed"), patch.object(self.driver, "drive", drive), \
             patch.object(self.driver, "cleanup_fixture", lambda fixture, case: cleaned.append((fixture, case))), \
             patch.object(self.driver, "require_cleanup", lambda fixture, case, receipt: cleaned.append((fixture, case))), \
             patch.object(self.driver, "csv_files", lambda complete=False: {}), patch.object(self.driver, "booking_files", lambda complete=False: {}):
            # argparse reads the process argv; driver imports no private CLI wrapper.
            with patch.object(sys, "argv", ["driver.py", "csv-flawed"]): self.assertEqual(0, self.driver.main())
            with patch.object(sys, "argv", ["driver.py", "csv-complete"]): self.assertEqual(0, self.driver.main())
            with patch.object(sys, "argv", ["driver.py", "booking-flawed"]): self.assertEqual(0, self.driver.main())
            with patch.object(sys, "argv", ["driver.py", "booking-complete"]): self.assertEqual(0, self.driver.main())
            with patch.object(sys, "argv", ["driver.py", "csv-continuation"]): self.assertEqual(0, self.driver.main())
        self.assertEqual(["csv-flawed", "csv-complete", "booking-flawed", "booking-complete"], [entry[1] for entry in routed if entry[0] == "setup"])
        continuation = next(entry for entry in routed if entry[0] == "drive" and entry[1] == "csv-continuation")
        self.assertEqual((self.runtime / "csv-continuation").resolve(), continuation[2])
        self.assertTrue(continuation[-1])
        self.assertEqual(2, continuation[4])


if __name__ == "__main__": unittest.main()
