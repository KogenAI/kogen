#!/usr/bin/env python3
"""driver-turn-end-replay: replays trimmed excerpts of real retained
shaping-evaluation rollouts (see replay/PROVENANCE.json) through the driver's
own task_complete_count, user_turn_terminal and turn_end_decision -- never a
reimplementation of that logic. Missing excerpts fail the test rather than
skipping it or inventing data.
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER_PATH = HERE / "driver.py"
REPLAY_DIR = HERE / "replay"


def load_driver(runtime):
    # driver.py resolves its runtime directory at import time; this test
    # never runs the suite/cases, so a throwaway directory is sufficient.
    old = os.environ.get("KOGEN_SHAPING_EVALUATION_RUNTIME")
    os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = str(runtime)
    try:
        spec = importlib.util.spec_from_file_location("replay_driver", DRIVER_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if old is None:
            os.environ.pop("KOGEN_SHAPING_EVALUATION_RUNTIME", None)
        else:
            os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = old


class DriverTurnEndReplayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temp = tempfile.TemporaryDirectory(prefix="kogen-driver-replay-")
        cls.driver = load_driver(Path(cls._temp.name))
        provenance_path = REPLAY_DIR / "PROVENANCE.json"
        if not provenance_path.is_file():
            raise AssertionError(
                f"driver-turn-end-replay sources are missing: {provenance_path} does not exist"
            )
        cls.provenance = json.loads(provenance_path.read_text())
        # Several cases now have more than one excerpt (a root rollout plus
        # any subagent rollouts), so excerpts are keyed by file name; the two
        # single-rollout failure cases are still reachable by their (unique)
        # case name via excerpts_by_case for readability below.
        cls.excerpts_by_file = {entry["file"]: entry for entry in cls.provenance["excerpts"]}
        cls.excerpts_by_case = {}
        for entry in cls.provenance["excerpts"]:
            cls.excerpts_by_case.setdefault(entry["case"], []).append(entry)
        for entry in cls.provenance["excerpts"]:
            path = REPLAY_DIR / entry["file"]
            if not path.is_file():
                raise AssertionError(f"driver-turn-end-replay excerpt is missing: {path}")

    @classmethod
    def tearDownClass(cls):
        cls._temp.cleanup()

    def load_events(self, filename):
        path = REPLAY_DIR / filename
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def test_passing_case_never_fires_fail_fast_and_reaches_its_recorded_outcome(self):
        """csv-flawed: a real completed scripted turn. The driver's own
        task_complete_count and user_turn_terminal see two completed native
        turns and a correctly bound scripted reply; turn_end_decision never
        fires fail-fast because the real captured Draft carried every
        required file."""
        entry = self.excerpts_by_file["csv-flawed-root.jsonl"]
        path = REPLAY_DIR / entry["file"]

        # driver's own task_complete_count, unmodified, over the real trimmed rollout.
        self.assertEqual(2, self.driver.task_complete_count(path))

        events = self.load_events(entry["file"])
        submitted = self.driver.transport_message(self.driver.CSV_ANSWER)
        turn_id, complete = self.driver.user_turn_terminal(path, [{"text": submitted}])
        self.assertTrue(complete)
        self.assertEqual("01a0c441-4d63-71c3-8f5e-e553c99fbf69", turn_id)

        # The real captured Draft for this run held every required file
        # (see .kogen/runtime/<run>/runs/csv-flawed/draft/ in the control
        # checkout): the driver's own fail-fast decision must not fire.
        outcome, reason = self.driver.turn_end_decision(
            "csv-flawed", 1, [self.driver.CSV_ANSWER],
            {"intent.yaml", "scenarios.yaml", "questions.md", "references.yaml", "risks.yaml", "walkthrough.md"},
        )
        self.assertEqual("complete", outcome)
        self.assertIsNone(reason)

    def test_every_passing_case_reaches_its_recorded_outcome_without_fail_fast(self):
        """Every case of the passing run shaping-evaluation-1789998731105-554
        (csv-flawed, csv-complete, booking-flawed, booking-complete,
        csv-continuation, stateful-flawed, stateful-complete) is covered by one
        excerpt per real retained rollout (root plus any subagent rollouts).
        For each: the driver's own task_complete_count matches the recorded
        completed-turn count on every rollout, the driver's own
        user_turn_terminal binds every scripted answer that was actually sent
        to a real terminal native turn, and the driver's own turn_end_decision
        never fires fail-fast at any turn end -- because the real captured
        Draft for that case held every file turn_end_decision requires."""
        scripted_texts_by_name = {
            "CSV_ANSWER": self.driver.CSV_ANSWER,
            "BOOKING_ANSWER": self.driver.BOOKING_ANSWER,
            "CSV_CONT_PARTIAL": self.driver.CSV_CONT_PARTIAL,
            "CSV_CONT_FINAL": self.driver.CSV_CONT_FINAL,
        }
        passing_run = self.provenance["passing_run"]
        cases = passing_run["cases"]
        self.assertEqual(
            {"csv-flawed", "csv-complete", "booking-flawed", "booking-complete",
             "csv-continuation", "stateful-flawed", "stateful-complete"},
            set(cases),
        )
        for case, recorded in cases.items():
            with self.subTest(case=case):
                rollout_files = recorded["rollout_files"]
                expected_counts = recorded["task_complete_counts"]
                self.assertEqual(len(rollout_files), len(expected_counts))

                # driver's own task_complete_count, unmodified, over every real
                # trimmed rollout of this case (root plus any subagents).
                for filename, expected_count in zip(rollout_files, expected_counts):
                    path = REPLAY_DIR / filename
                    self.assertTrue(path.is_file(), f"{case}: missing excerpt {filename}")
                    self.assertEqual(
                        expected_count, self.driver.task_complete_count(path),
                        f"{case}: {filename}",
                    )

                scripted_names = recorded["scripted_messages_sent"]
                scripted_texts = [scripted_texts_by_name[name] for name in scripted_names]

                # The root rollout carries every resumed scripted answer (if
                # any); the driver's own ordered binding must see each one
                # reach a real terminal native turn, never a reimplementation.
                root_path = REPLAY_DIR / rollout_files[0]
                if scripted_texts:
                    submitted = [{"text": self.driver.transport_message(text)} for text in scripted_texts]
                    turn_id, complete = self.driver.user_turn_terminal(root_path, submitted)
                    self.assertTrue(
                        complete,
                        f"{case}: driver.user_turn_terminal did not bind every scripted answer to a terminal turn",
                    )
                    self.assertIsNotNone(turn_id)

                # turn_end_decision must never fire fail-fast at any turn end of
                # this case. Feed it the real captured Draft's file set (from
                # PROVENANCE.json) at each point: "advance" while a scripted
                # message remains, "complete" once none does, because the real
                # Draft held every required file -- modeling the Draft-state
                # input the same way test_passing_case_never_fires_fail_fast
                # does for csv-flawed, so a false positive between a turn's end
                # and the Draft settling cannot appear here either.
                draft_files = set(recorded["draft_files"])
                self.assertTrue(recorded["final_draft_has_scenarios_yaml"])
                self.assertIn("scenarios.yaml", draft_files)
                for next_msg in range(len(scripted_texts) + 1):
                    outcome, reason = self.driver.turn_end_decision(case, next_msg, scripted_texts, draft_files)
                    if next_msg < len(scripted_texts):
                        self.assertEqual("advance", outcome, f"{case} turn {next_msg}")
                        self.assertIsNone(reason)
                    else:
                        self.assertEqual("complete", outcome, f"{case} turn {next_msg}: {reason}")
                        self.assertIsNone(reason)

    def test_every_excerpt_provenance_header_is_present(self):
        """Every excerpt entry (passing and failure) carries the header fields
        the replay depends on to trust it is a real, hashed, sourced slice of
        a retained rollout -- not invented data."""
        required_fields = {
            "file", "case", "run_dir", "run_relative_path",
            "original_raw_rollout_relative_path", "original_raw_rollout_sha256",
            "owned_concise_rollout_sha256", "kept_line_indices_in_owned_rollout",
            "kept_line_count", "owned_rollout_total_lines",
        }
        self.assertTrue(self.provenance["excerpts"])
        for entry in self.provenance["excerpts"]:
            missing = required_fields - set(entry)
            self.assertFalse(missing, f"{entry.get('file')}: missing provenance fields {missing}")
            self.assertEqual(entry["kept_line_count"], len(entry["kept_line_indices_in_owned_rollout"]))
            self.assertLessEqual(entry["kept_line_count"], entry["owned_rollout_total_lines"])

    def _assert_stateful_fails_fast(self, case):
        """Real retained runs of this case completed their only native turn
        (task_complete_count == 1) yet their captured Draft never saved
        scenarios.yaml -- exactly the gap driver.turn_end_decision now catches
        at that turn's end, naming the case and the missing evidence, instead
        of letting the suite discover it only after every case finishes."""
        entry = self.excerpts_by_file[f"{case}-root.jsonl"]
        path = REPLAY_DIR / entry["file"]
        self.assertEqual(1, self.driver.task_complete_count(path))

        outcome, reason = self.driver.turn_end_decision(
            case, 0, [], set(entry["observed_draft_files"]) - {"evidence"}
        )
        self.assertEqual("fail", outcome)
        self.assertIn(case, reason)
        self.assertIn("scenarios.yaml", reason)

    def test_stateful_complete_replay_fails_fast_on_the_real_missing_scenarios_yaml(self):
        self._assert_stateful_fails_fast("stateful-complete")

    def test_stateful_flawed_replay_fails_fast_on_the_real_missing_scenarios_yaml(self):
        self._assert_stateful_fails_fast("stateful-flawed")


if __name__ == "__main__":
    unittest.main()
