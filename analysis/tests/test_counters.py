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
        # Transcript leg only (run) — clean session has no Stop hook feedback.
        findings = self.counter.run(self.clean, _clean_config())
        self.assertEqual(findings, [])

    def test_excludes_breaker_and_stale_rule(self) -> None:
        from analysis.session_loader import Session, Turn

        turns = [
            Turn(
                index=0,
                kind="user",
                timestamp="",
                cwd="",
                user_text="Stop hook feedback: stop-gate-failure-breaker — escalation",
            ),
            Turn(
                index=1,
                kind="user",
                timestamp="",
                cwd="",
                user_text="Stop hook feedback: step-log-completeness — stale rule",
            ),
        ]
        session = Session("x", Path("/tmp/x.jsonl"), turns)
        findings = self.counter.run(session, _thrash_config())
        self.assertEqual(findings, [])

    def test_gate_verdict_substrate_repo_level(self) -> None:
        # fixtures/gate-verdicts.jsonl has 2 failed entries, both session_thrash
        findings = self.counter.run_repo(_thrash_config())
        gate_findings = [f for f in findings if f.pattern_key == "gate:failed"]
        self.assertEqual(len(gate_findings), 2)

    def test_gate_verdict_not_multiplied_by_session_count(self) -> None:
        # Regression: gate-leg wasted_turns must equal real record count,
        # never real_count × number-of-sessions-that-called-run().
        findings = self.counter.run_repo(_thrash_config())
        total_wasted = sum(
            f.wasted_turns for f in findings if f.pattern_key == "gate:failed"
        )
        self.assertEqual(total_wasted, 4)  # 2 failed records × weight 2


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

    def test_returns_empty_when_substrate_absent(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = self.counter.run_repo(cfg)
        self.assertEqual(findings, [])

    def test_only_real_waste_is_counted(self) -> None:
        # fixtures/failures.jsonl: 1 oversized-read (waste, isolated), 1
        # missing-file (expected, excluded), 1 interrupted (expected,
        # excluded), 2 dir-read (waste, gap-separated -> recovered), 3
        # bad-arg (waste, tight gaps -> spiral).
        findings = self.counter.run_repo(_thrash_config())
        keys = {f.pattern_key for f in findings if f.wasted_turns > 0}
        self.assertEqual(
            keys, {"Read×oversized-read", "Read×dir-read", "Bash×bad-arg:spiral"}
        )

    def test_excludes_expected_failures(self) -> None:
        findings = self.counter.run_repo(_thrash_config())
        total_wasted = sum(f.wasted_turns for f in findings)
        # oversized-read(1) + dir-read(1+1, recovered) + bad-arg(3*2, spiral)
        # = 1 + 2 + 6 = 9. missing-file and interrupted are excluded.
        self.assertEqual(total_wasted, 9)

    def test_counter_name(self) -> None:
        findings = self.counter.run_repo(_thrash_config())
        for f in findings:
            self.assertEqual(f.counter, "tool_failure")

    def test_not_multiplied_by_session_count(self) -> None:
        # Regression: repo-level run_repo scans the substrate ONCE regardless
        # of how many sessions exist — wasted_turns must equal real weighted
        # waste, never weighted_count × session_count.
        findings = self.counter.run_repo(_thrash_config())
        total_wasted = sum(f.wasted_turns for f in findings)
        self.assertEqual(total_wasted, 9)

    def test_recovered_failures_stay_isolated_weight_one(self) -> None:
        # Gap-separated same-class records (359s > spiral_gap_seconds=300)
        # recover between incidents -> each counts as its own weight-1
        # finding under the base (non-spiral) pattern_key, never merged.
        findings = self.counter.run_repo(_thrash_config())
        dir_read = [f for f in findings if f.pattern_key == "Read×dir-read"]
        self.assertEqual(sum(f.wasted_turns for f in dir_read), 2)
        self.assertNotIn(
            "Read×dir-read:spiral", {f.pattern_key for f in findings}
        )

    def test_spiral_run_out_ranks_equal_count_scattered(self) -> None:
        # 3 consecutive Bash×bad-arg records within the gap threshold form a
        # spiral: pattern_key carries the :spiral suffix and weight is
        # run_length * 2 (6), strictly greater than 3 equal scattered
        # (weight-1) findings would sum to.
        findings = self.counter.run_repo(_thrash_config())
        spiral = [f for f in findings if f.pattern_key == "Bash×bad-arg:spiral"]
        self.assertEqual(len(spiral), 1)
        self.assertEqual(spiral[0].wasted_turns, 6)
        self.assertGreater(spiral[0].wasted_turns, 3)

    def test_run_group_file_isolated_ts_unparseable_is_fail_safe(self) -> None:
        # Records with an unparseable/missing ts cannot be run-grouped and
        # must fall back to isolated (recovered, weight-1) rather than
        # crashing or silently merging into a spiral.
        from analysis.counters.tool_failure import _run_group_file

        records = [
            {"tool": "Read", "error": "Read exceeds maximum size", "_line": "a"},
            {"tool": "Read", "error": "Read exceeds maximum size", "_line": "b"},
        ]
        entries = _run_group_file(records, _thrash_config())
        self.assertEqual(entries, [("Read×oversized-read", 1, "a"), ("Read×oversized-read", 1, "b")])

    def test_classify_waste_classes(self) -> None:
        from analysis.counters.tool_failure import _classify

        self.assertEqual(_classify("Read", "Read exceeds maximum size"), ("oversized-read", True))
        self.assertEqual(_classify("Read", "EISDIR: illegal operation"), ("dir-read", True))
        self.assertEqual(_classify("Bash", "unsupported role"), ("bad-arg", True))
        self.assertEqual(_classify("Agent", "not found"), ("agent-not-found", True))

    def test_classify_expected_classes(self) -> None:
        from analysis.counters.tool_failure import _classify

        self.assertEqual(
            _classify("Agent", "[Request interrupted by user for tool use]"),
            ("expected", False),
        )
        self.assertEqual(
            _classify("Read", "File does not exist. Note: ..."), ("expected", False)
        )
        self.assertEqual(_classify("Bash", "cat: illegal option"), ("guard-hit", False))
        self.assertEqual(_classify("Bash", "Exit code 1"), ("exit-signal", False))


class TestBoundedMagnitude(unittest.TestCase):
    """Regression: no repo-level counter's wasted_turns may exceed its own
    substrate record count. Guards against the per-session re-emission bug
    (real_count × session_count) silently regressing and re-taking rank #1.
    """

    def test_tool_failure_bounded_by_substrate_size(self) -> None:
        from analysis.counters import tool_failure

        cfg = _thrash_config()
        substrate_path = FIXTURES / "failures.jsonl"
        with open(substrate_path, encoding="utf-8") as fh:
            record_count = sum(1 for line in fh if line.strip())

        findings = tool_failure.run_repo(cfg)
        total_wasted = sum(f.wasted_turns for f in findings)
        # spiral runs weight run_length * 2, so the ceiling is 2x record
        # count, not record_count itself (mirrors hook_intervention's
        # weight=2 bound below).
        self.assertLessEqual(total_wasted, record_count * 2)

    def test_hook_intervention_gate_leg_bounded_by_substrate_size(self) -> None:
        from analysis.counters import hook_intervention

        cfg = _thrash_config()
        substrate_path = FIXTURES / "gate-verdicts.jsonl"
        with open(substrate_path, encoding="utf-8") as fh:
            record_count = sum(1 for line in fh if line.strip())

        findings = hook_intervention.run_repo(cfg)
        # weight=2 per failed record, so the ceiling is 2× record_count, not
        # record_count × number-of-callers.
        total_wasted = sum(f.wasted_turns for f in findings)
        self.assertLessEqual(total_wasted, record_count * 2)


class TestRepoCounterWindowing(unittest.TestCase):
    """Regression: repo-level counters must honor --since per-record, not
    report lifetime evidence unconditionally.
    """

    def test_tool_failure_excludes_out_of_window_record(self) -> None:
        import tempfile
        from analysis.counters import tool_failure

        with tempfile.TemporaryDirectory() as tmpdir:
            substrate = Path(tmpdir) / "session_a.jsonl"
            substrate.write_text(
                '{"ts": "2020-01-01T00:00:00Z", "tool": "Read", "error": "Read exceeds maximum size", "agent": "x"}\n'
                '{"ts": "2026-06-19T10:00:00Z", "tool": "Read", "error": "Read exceeds maximum size", "agent": "x"}\n',
                encoding="utf-8",
            )
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = tool_failure.run_repo(cfg)
            total_wasted = sum(f.wasted_turns for f in findings)
            # Only the in-window record counted; the out-of-window one dropped.
            self.assertEqual(total_wasted, 1)

    def test_hook_intervention_gate_leg_excludes_out_of_window_record(self) -> None:
        import tempfile
        from analysis.counters import hook_intervention

        with tempfile.TemporaryDirectory() as tmpdir:
            substrate = Path(tmpdir) / "gate-verdicts.jsonl"
            substrate.write_text(
                '{"verdict": "failed", "started": "2020-01-01T00:00:00Z", "ended": "2020-01-01T00:00:00Z", "session_id": "s"}\n'
                '{"verdict": "failed", "started": "2026-06-19T10:00:00Z", "ended": "2026-06-19T10:00:00Z", "session_id": "s"}\n',
                encoding="utf-8",
            )
            cfg = Config(
                since=datetime.date(2026, 1, 1),
                project_dir=Path(tmpdir),
                codegen_dir=CODEGEN_DIR,
            )
            findings = hook_intervention.run_repo(cfg)
            gate_findings = [f for f in findings if f.pattern_key == "gate:failed"]
            # Only the in-window failed record counted.
            self.assertEqual(len(gate_findings), 1)


if __name__ == "__main__":
    unittest.main()
