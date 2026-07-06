"""Tests for each counter — fires on thrash fixture, silent on clean fixture."""
import datetime
import unittest
from pathlib import Path

from analysis.config import Config
from analysis.session_loader import iter_sessions

FIXTURES = Path(__file__).parent / "fixtures"
CODEGEN_DIR = Path(__file__).parent.parent.parent  # repo root


def _sessions_from_fixture(filename: str, config: "Config"):
    """Load exactly one fixture file as a list of sessions."""
    from analysis.session_loader import _load_jsonl, Session, _session_id_from_path

    path = FIXTURES / filename
    turns = _load_jsonl(path)
    session = Session(
        session_id=_session_id_from_path(path),
        path=path,
        turns=turns,
    )
    return session


def _thrash_config() -> Config:
    return Config(
        since=datetime.date(2026, 1, 1),
        project_dir=FIXTURES,
        codegen_dir=CODEGEN_DIR,
        reread_threshold=2,
        window=2,
    )


def _clean_config() -> Config:
    return Config(
        since=datetime.date(2026, 1, 1),
        project_dir=FIXTURES,
        codegen_dir=CODEGEN_DIR,
        reread_threshold=2,
        window=2,
    )


class TestForbiddenBash(unittest.TestCase):
    def setUp(self) -> None:
        from analysis.counters import forbidden_bash

        self.counter = forbidden_bash
        self.thrash = _sessions_from_fixture("session_thrash.jsonl", _thrash_config())
        self.clean = _sessions_from_fixture("session_clean.jsonl", _clean_config())

    def test_fires_on_thrash(self) -> None:
        findings = self.counter.run(self.thrash, _thrash_config())
        self.assertGreater(len(findings), 0)
        # Should detect no-cat-pipe
        ids = {f.pattern_key for f in findings}
        self.assertIn("no-cat-pipe", ids)

    def test_silent_on_clean(self) -> None:
        findings = self.counter.run(self.clean, _clean_config())
        self.assertEqual(findings, [])

    def test_finding_fields(self) -> None:
        findings = self.counter.run(self.thrash, _thrash_config())
        f = findings[0]
        self.assertEqual(f.counter, "forbidden_bash")
        self.assertIsInstance(f.pattern_key, str)
        self.assertGreater(f.wasted_turns, 0)
        self.assertIsInstance(f.evidence, str)


class TestReRead(unittest.TestCase):
    def setUp(self) -> None:
        from analysis.counters import re_read

        self.counter = re_read
        self.thrash = _sessions_from_fixture("session_thrash.jsonl", _thrash_config())
        self.clean = _sessions_from_fixture("session_clean.jsonl", _clean_config())

    def test_fires_on_thrash(self) -> None:
        # session_thrash reads lib/foo.ex 3 times (threshold=2 → fires at >2)
        findings = self.counter.run(self.thrash, _thrash_config())
        self.assertGreater(len(findings), 0)
        keys = {f.pattern_key for f in findings}
        self.assertIn("lib/foo.ex", keys)

    def test_silent_on_clean(self) -> None:
        # session_clean reads lib/bar.ex only once
        findings = self.counter.run(self.clean, _clean_config())
        self.assertEqual(findings, [])

    def test_threshold_boundary(self) -> None:
        # Exactly at threshold (2 reads) → not flagged; 3 reads → flagged
        from analysis.session_loader import Session, Turn, ToolUse

        def make_session(n_reads: int) -> Session:
            turns = []
            for i in range(n_reads):
                turns.append(
                    Turn(
                        index=i,
                        kind="assistant",
                        timestamp="",
                        cwd="",
                        tool_uses=[ToolUse("id", "Read", file_path="x.ex")],
                    )
                )
            return Session("test", Path("/tmp/x.jsonl"), turns)

        cfg = _thrash_config()
        self.assertEqual(self.counter.run(make_session(2), cfg), [])
        self.assertGreater(len(self.counter.run(make_session(3), cfg)), 0)


class TestHookIntervention(unittest.TestCase):
    def setUp(self) -> None:
        from analysis.counters import hook_intervention

        self.counter = hook_intervention
        self.thrash = _sessions_from_fixture("session_thrash.jsonl", _thrash_config())
        self.clean = _sessions_from_fixture("session_clean.jsonl", _clean_config())

    def test_fires_on_thrash(self) -> None:
        findings = self.counter.run(self.thrash, _thrash_config())
        self.assertGreater(len(findings), 0)

    def test_extracts_rule_name(self) -> None:
        findings = self.counter.run(self.thrash, _thrash_config())
        keys = {f.pattern_key for f in findings}
        self.assertIn("no-cat-pipe", keys)

    def test_silent_on_clean(self) -> None:
        findings = self.counter.run(self.clean, _clean_config())
        # No hook feedback or gate verdicts for clean session (substrate present in fixtures)
        # gate-verdicts.jsonl has failed entries → findings from substrate
        # We only assert transcript part is silent (no Stop hook feedback: in clean)
        transcript_findings = [
            f for f in findings if f.pattern_key != "gate:failed"
        ]
        self.assertEqual(transcript_findings, [])

    def test_gate_verdict_substrate(self) -> None:
        # project_dir has gate-verdicts.jsonl with 2 failed entries
        findings = self.counter.run(self.thrash, _thrash_config())
        gate_findings = [f for f in findings if f.pattern_key == "gate:failed"]
        self.assertEqual(len(gate_findings), 2)


class TestUserCorrection(unittest.TestCase):
    def setUp(self) -> None:
        from analysis.counters import user_correction

        self.counter = user_correction
        self.thrash = _sessions_from_fixture("session_thrash.jsonl", _thrash_config())
        self.clean = _sessions_from_fixture("session_clean.jsonl", _clean_config())

    def test_fires_on_thrash(self) -> None:
        findings = self.counter.run(self.thrash, _thrash_config())
        self.assertGreater(len(findings), 0)

    def test_silent_on_clean(self) -> None:
        findings = self.counter.run(self.clean, _clean_config())
        self.assertEqual(findings, [])

    def test_strong_phrase_weighted(self) -> None:
        # "undo" is in _STRONG_RE → wasted_turns=2
        findings = self.counter.run(self.thrash, _thrash_config())
        self.assertTrue(any(f.wasted_turns == 2 for f in findings))

    def test_hook_feedback_excluded(self) -> None:
        # "Stop hook feedback:" lines must not be flagged as user corrections
        from analysis.session_loader import Session, Turn

        turns = [
            Turn(
                index=0,
                kind="user",
                timestamp="",
                cwd="",
                user_text="Stop hook feedback: no-cat-pipe — wrong",
            )
        ]
        session = Session("x", Path("/tmp/x.jsonl"), turns)
        findings = self.counter.run(session, _thrash_config())
        self.assertEqual(findings, [])


class TestDelegationChurn(unittest.TestCase):
    def setUp(self) -> None:
        from analysis.counters import delegation_churn

        self.counter = delegation_churn
        self.thrash = _sessions_from_fixture("session_thrash.jsonl", _thrash_config())
        self.clean = _sessions_from_fixture("session_clean.jsonl", _clean_config())

    def test_fires_with_no_step_log(self) -> None:
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = self.counter.run(self.thrash, cfg)
        # thrash session has an Agent spawn → no step log in tmpdir → finding
        self.assertGreater(len(findings), 0)
        self.assertTrue(
            all(f.pattern_key == "delegation:no-step-log" for f in findings)
        )

    def test_silent_when_step_log_present(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            # Create a fake cycle log
            fake_log = Path(tmpdir) / "20260619_000000_foo_cycle.jsonl"
            fake_log.write_text('{"ev":"init","pitch":"foo","path":"","stamp":{}}\n')
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = self.counter.run(self.thrash, cfg)
        self.assertEqual(findings, [])

    def test_silent_on_clean(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = self.counter.run(self.clean, cfg)
        # clean session has no Agent spawns
        self.assertEqual(findings, [])


class TestToolFailure(unittest.TestCase):
    def setUp(self) -> None:
        from analysis.counters import tool_failure

        self.counter = tool_failure
        self.thrash = _sessions_from_fixture("session_thrash.jsonl", _thrash_config())

    def test_returns_empty_when_substrate_absent(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = self.counter.run(self.thrash, cfg)
        self.assertEqual(findings, [])

    def test_clusters_when_substrate_present(self) -> None:
        # fixtures/failures.jsonl has 3 records: Bash×developer, Read×developer, Bash×committer
        findings = self.counter.run(self.thrash, _thrash_config())
        self.assertGreater(len(findings), 0)
        keys = {f.pattern_key for f in findings}
        self.assertTrue(
            any("Bash" in k for k in keys), f"No Bash key in {keys}"
        )

    def test_counter_name(self) -> None:
        findings = self.counter.run(self.thrash, _thrash_config())
        for f in findings:
            self.assertEqual(f.counter, "tool_failure")


if __name__ == "__main__":
    unittest.main()
