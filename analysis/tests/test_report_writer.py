"""Tests for analysis.report_writer."""
import json
import unittest

from analysis.analyzer import Cluster, Report
from analysis.report_writer import render_report


def _make_report(clusters=None, substrate_present=False):
    return Report(
        clusters=clusters or [],
        substrate_present=substrate_present,
        pi_only_sessions=0,
        project_label="/tmp/project",
        since_label="2026-06-01",
    )


class TestRenderReportEmpty(unittest.TestCase):
    def test_no_sessions_message(self) -> None:
        report = _make_report([])
        output = render_report(report)
        self.assertIn("no sessions found", output)
        self.assertIn("/tmp/project", output)
        self.assertIn("2026-06-01", output)

    def test_json_mode_empty_is_empty_string(self) -> None:
        report = _make_report([])
        output = render_report(report, as_json=True)
        # Empty report → "no sessions found" still (json mode preserves the empty message)
        self.assertIn("no sessions found", output)


class TestRenderReportHuman(unittest.TestCase):
    def setUp(self) -> None:
        self.clusters = [
            Cluster("forbidden_bash", "no-cat-pipe", 6, 3, "evidence A"),
            Cluster("re_read", "lib/foo.ex", 2, 1, "evidence B"),
        ]
        self.report = _make_report(self.clusters, substrate_present=True)

    def test_table_contains_counter_names(self) -> None:
        output = render_report(self.report)
        self.assertIn("forbidden_bash", output)
        self.assertIn("re_read", output)

    def test_table_contains_pattern_keys(self) -> None:
        output = render_report(self.report)
        self.assertIn("no-cat-pipe", output)
        self.assertIn("lib/foo.ex", output)

    def test_table_contains_turns_wasted(self) -> None:
        output = render_report(self.report)
        self.assertIn("6", output)

    def test_substrate_absent_note(self) -> None:
        report = _make_report(self.clusters, substrate_present=False)
        output = render_report(report)
        self.assertIn("substrate not found", output)

    def test_no_substrate_note_when_present(self) -> None:
        output = render_report(self.report)
        self.assertNotIn("substrate not found", output)

    def test_ranking_order_is_wasted_turns_desc(self) -> None:
        # forbidden_bash has 6 wasted_turns, re_read has 2 → forbidden_bash first
        output = render_report(self.report)
        idx_forbidden = output.index("forbidden_bash")
        idx_reread = output.index("re_read")
        self.assertLess(idx_forbidden, idx_reread)


class TestRenderReportJson(unittest.TestCase):
    def setUp(self) -> None:
        self.clusters = [
            Cluster("hook_intervention", "no-cat-pipe", 4, 2, "evidence X"),
            Cluster("user_correction", "correction", 1, 1, "evidence Y"),
        ]
        self.report = _make_report(self.clusters)

    def test_one_json_object_per_cluster(self) -> None:
        output = render_report(self.report, as_json=True)
        lines = [l for l in output.strip().split("\n") if l.strip()]
        self.assertEqual(len(lines), len(self.clusters))

    def test_each_line_is_valid_json(self) -> None:
        output = render_report(self.report, as_json=True)
        for line in output.strip().split("\n"):
            if line.strip():
                obj = json.loads(line)  # raises if invalid
                self.assertIn("counter", obj)
                self.assertIn("pattern_key", obj)
                self.assertIn("wasted_turns", obj)
                self.assertIn("sessions", obj)

    def test_json_contains_correct_values(self) -> None:
        output = render_report(self.report, as_json=True)
        objs = [json.loads(l) for l in output.strip().split("\n") if l.strip()]
        counters = [o["counter"] for o in objs]
        self.assertIn("hook_intervention", counters)
        self.assertIn("user_correction", counters)


if __name__ == "__main__":
    unittest.main()
