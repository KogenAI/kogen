"""Tests for the repo-level subagent-interruption marker counter."""
import datetime
import tempfile
import unittest
from pathlib import Path

from analysis.config import Config
from analysis.counters.subagent_interruption import run_repo

FIXTURES = Path(__file__).parent / "fixtures"


def _cfg(project_dir: Path) -> Config:
    return Config(
        since=datetime.date(2026, 1, 1),
        project_dir=project_dir,
    )


class TestSubagentInterruption(unittest.TestCase):
    def setUp(self) -> None:
        self.findings = run_repo(_cfg(FIXTURES))
        self.by_key = {f.pattern_key: f for f in self.findings}

    def test_both_died_kinds_detected(self) -> None:
        self.assertEqual(
            {"interrupted", "aborted"},
            {f.pattern_key for f in self.findings},
        )

    def test_wasted_turns_weights(self) -> None:
        self.assertEqual(self.by_key["interrupted"].wasted_turns, 2)
        self.assertEqual(self.by_key["aborted"].wasted_turns, 3)

    def test_counter_name(self) -> None:
        for f in self.findings:
            self.assertEqual(f.counter, "subagent_interruption")

    def test_session_id_is_basename(self) -> None:
        for f in self.findings:
            self.assertEqual(f.session_id, "session_interruptions_cycle.jsonl")

    def test_turn_index_is_line_number(self) -> None:
        for f in self.findings:
            self.assertGreater(f.turn_index, 0)
        self.assertLess(
            self.by_key["interrupted"].turn_index,
            self.by_key["aborted"].turn_index,
        )

    def test_evidence_is_died_event_line(self) -> None:
        self.assertIn('"kind":"interrupted"', self.by_key["interrupted"].evidence)
        self.assertIn('"kind":"aborted"', self.by_key["aborted"].evidence)

    def test_non_died_events_ignored(self) -> None:
        self.assertNotIn(
            "What I Learned This Step",
            {f.evidence for f in self.findings},
        )

    def test_absent_logging_dir_returns_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "does_not_exist"
            self.assertEqual(run_repo(_cfg(missing)), [])

    def test_empty_logging_dir_returns_empty(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(run_repo(_cfg(Path(tmp))), [])

    def test_malformed_line_fail_open_skip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "broken_cycle.jsonl"
            log.write_text(
                "not-json-at-all\n"
                '{"ev":"died","role":"developer-phoenix-backend","kind":"interrupted"}\n'
                '{"ev":"role","role":"planner-phoenix","body":"prose"}\n',
                encoding="utf-8",
            )
            findings = run_repo(_cfg(Path(tmp)))
            self.assertEqual(len(findings), 1)
            self.assertEqual(findings[0].pattern_key, "interrupted")


if __name__ == "__main__":
    unittest.main()
