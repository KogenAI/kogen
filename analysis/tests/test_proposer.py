"""Tests for analysis.proposer.select — pure cluster selection logic."""
import unittest

from analysis.counters import ALL_COUNTERS, ALL_REPO_COUNTERS
from analysis.proposer import COUNTER_CONFIDENCE_PRIOR, COUNTER_FIX_TYPE
from analysis.proposer.select import select_clusters


def _cluster(counter: str, pattern_key: str, wasted_turns: int) -> dict:
    return {
        "counter": counter,
        "pattern_key": pattern_key,
        "wasted_turns": wasted_turns,
        "sessions": 1,
        "top_evidence": f"evidence for {pattern_key}",
    }


class SelectClustersTests(unittest.TestCase):
    def test_drops_clusters_below_min_wasted_turns(self):
        clusters = [
            _cluster("forbidden_bash", "low-waste", 1),
            _cluster("forbidden_bash", "high-waste", 10),
        ]
        result = select_clusters(clusters, min_wasted_turns=4, max_proposals=5)
        pattern_keys = [c["pattern_key"] for c in result]
        self.assertEqual(pattern_keys, ["high-waste"])

    def test_drops_subagent_interruption_even_with_high_wasted_turns(self):
        clusters = [
            _cluster("subagent_interruption", "infra-flake", 100),
            _cluster("forbidden_bash", "real-bug", 5),
        ]
        result = select_clusters(clusters, min_wasted_turns=4, max_proposals=5)
        pattern_keys = [c["pattern_key"] for c in result]
        self.assertEqual(pattern_keys, ["real-bug"])

    def test_sort_order_by_weighted_prior_times_wasted_turns(self):
        # weight = prior_rank(counter) * wasted_turns
        # high=3, medium=2, low=1 (subagent_interruption is low but dropped
        # by default separately — not used here to isolate sort behavior)
        clusters = [
            _cluster("re_read", "medium-8", 8),  # weight = 2*8 = 16
            _cluster("forbidden_bash", "high-4", 4),  # weight = 3*4 = 12
            _cluster("user_correction", "high-6", 6),  # weight = 3*6 = 18
            _cluster("tool_failure", "medium-4", 4),  # weight = 2*4 = 8
        ]
        result = select_clusters(clusters, min_wasted_turns=4, max_proposals=10)
        pattern_keys = [c["pattern_key"] for c in result]
        # Literal expected ordering: 18, 16, 12, 8
        self.assertEqual(
            pattern_keys, ["high-6", "medium-8", "high-4", "medium-4"]
        )

    def test_tie_break_by_wasted_turns_then_pattern_key(self):
        clusters = [
            _cluster("forbidden_bash", "zzz-tied", 5),  # weight 15
            _cluster("forbidden_bash", "aaa-tied", 5),  # weight 15 (tie)
        ]
        result = select_clusters(clusters, min_wasted_turns=4, max_proposals=10)
        pattern_keys = [c["pattern_key"] for c in result]
        self.assertEqual(pattern_keys, ["aaa-tied", "zzz-tied"])

    def test_cap_at_max_proposals(self):
        clusters = [
            _cluster("forbidden_bash", f"cluster-{i}", 10 + i) for i in range(8)
        ]
        result = select_clusters(clusters, min_wasted_turns=4, max_proposals=5)
        self.assertEqual(len(result), 5)

    def test_empty_input_returns_empty_list(self):
        result = select_clusters([], min_wasted_turns=4, max_proposals=5)
        self.assertEqual(result, [])

    def test_playbook_and_prior_cover_every_counter(self):
        # Fail-loud completeness check: every counter known to the analyzer
        # must have both a fix-type playbook entry and a confidence prior.
        # This catches future counter additions that forget to update the
        # proposer's playbook.
        all_counters = list(ALL_COUNTERS) + list(ALL_REPO_COUNTERS)
        for counter in all_counters:
            self.assertIn(
                counter,
                COUNTER_FIX_TYPE,
                msg=f"counter {counter!r} missing from COUNTER_FIX_TYPE playbook",
            )
            self.assertIn(
                counter,
                COUNTER_CONFIDENCE_PRIOR,
                msg=f"counter {counter!r} missing from COUNTER_CONFIDENCE_PRIOR",
            )


if __name__ == "__main__":
    unittest.main()
