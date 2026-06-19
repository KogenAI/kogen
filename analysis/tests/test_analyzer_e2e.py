"""End-to-end test: thrash fixture → expected ranked findings."""
import datetime
import tempfile
import unittest
from pathlib import Path

from analysis.analyzer import run, Report
from analysis.config import Config

FIXTURES = Path(__file__).parent / "fixtures"
CODEGEN_DIR = Path(__file__).parent.parent.parent  # repo root


def _cfg(project_dir: Path) -> Config:
    return Config(
        since=datetime.date(2026, 1, 1),
        project_dir=project_dir,
        codegen_dir=CODEGEN_DIR,
        reread_threshold=2,
        window=2,
    )


class TestAnalyzerE2E(unittest.TestCase):
    def setUp(self) -> None:
        # Use fixtures dir which has thrash + clean + malformed sessions + substrate
        self.report = run(_cfg(FIXTURES))

    def test_returns_report(self) -> None:
        self.assertIsInstance(self.report, Report)

    def test_findings_ranked_wasted_turns_desc(self) -> None:
        clusters = self.report.clusters
        if len(clusters) < 2:
            return  # nothing to compare
        for i in range(len(clusters) - 1):
            self.assertGreaterEqual(
                clusters[i].wasted_turns,
                clusters[i + 1].wasted_turns,
                f"Cluster {i} wasted_turns ({clusters[i].wasted_turns}) < "
                f"cluster {i+1} ({clusters[i+1].wasted_turns})",
            )

    def test_forbidden_bash_detected(self) -> None:
        counters = {c.counter for c in self.report.clusters}
        self.assertIn(
            "forbidden_bash", counters, f"forbidden_bash not in {counters}"
        )

    def test_re_read_detected(self) -> None:
        # lib/foo.ex read 3× in thrash session → re_read finding
        keys = {c.pattern_key for c in self.report.clusters}
        self.assertIn("lib/foo.ex", keys, f"lib/foo.ex not in {keys}")

    def test_hook_intervention_detected(self) -> None:
        keys = {c.pattern_key for c in self.report.clusters}
        self.assertIn("no-cat-pipe", keys, f"no-cat-pipe not in {keys}")

    def test_substrate_present(self) -> None:
        # fixtures dir has gate-verdicts.jsonl → substrate_present True
        self.assertTrue(self.report.substrate_present)

    def test_no_sessions_case(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = _cfg(Path(tmpdir))
            report = run(cfg)
        self.assertEqual(report.clusters, [])

    def test_deterministic(self) -> None:
        """Two runs over the same fixture produce identical ranked output."""
        cfg = _cfg(FIXTURES)
        report1 = run(cfg)
        report2 = run(cfg)
        self.assertEqual(
            [(c.counter, c.pattern_key, c.wasted_turns) for c in report1.clusters],
            [(c.counter, c.pattern_key, c.wasted_turns) for c in report2.clusters],
        )


if __name__ == "__main__":
    unittest.main()
