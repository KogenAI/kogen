"""Unit tests for prompt_size_budget.py."""

import sys
import tempfile
import unittest
from pathlib import Path

_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import prompt_size_budget as psb  # noqa: E402


def _write(dirpath, name, content=""):
    p = Path(dirpath) / name
    p.write_text(content)
    return p


class ParseBudgetFileTest(unittest.TestCase):
    def test_parses_rows_and_skips_comments_and_blanks(self):
        with tempfile.TemporaryDirectory() as td:
            budget_path = _write(
                td,
                "prompt-budgets.txt",
                "# comment\n\nshared/rules/_core/fail-loud.md 25\n"
                "shared/subagents/shared/committer.md.j2 60265\n",
            )
            budgets = psb.parse_budget_file(budget_path)
            self.assertEqual(
                budgets,
                {
                    "shared/rules/_core/fail-loud.md": 25,
                    "shared/subagents/shared/committer.md.j2": 60265,
                },
            )

    def test_missing_file_returns_empty(self):
        budgets = psb.parse_budget_file(Path("/nonexistent/prompt-budgets.txt"))
        self.assertEqual(budgets, {})

    def test_malformed_row_skipped_not_raised(self):
        with tempfile.TemporaryDirectory() as td:
            budget_path = _write(td, "prompt-budgets.txt", "no-space-no-number\n")
            budgets = psb.parse_budget_file(budget_path)
            self.assertEqual(budgets, {})


class RenderBudgetFileTest(unittest.TestCase):
    def test_renders_both_sections_sorted(self):
        rule_sizes = {"shared/rules/_core/b.md": 10, "shared/rules/_core/a.md": 5}
        agent_sizes = {"shared/subagents/shared/z.md.j2": 100}
        rendered = psb.render_budget_file(rule_sizes, agent_sizes)
        # a.md sorts before b.md
        a_idx = rendered.index("shared/rules/_core/a.md 5")
        b_idx = rendered.index("shared/rules/_core/b.md 10")
        self.assertLess(a_idx, b_idx)
        self.assertIn("shared/subagents/shared/z.md.j2 100", rendered)

    def test_round_trips_through_parse(self):
        rule_sizes = {"shared/rules/_core/x.md": 42}
        agent_sizes = {"shared/subagents/shared/y.md.j2": 999}
        rendered = psb.render_budget_file(rule_sizes, agent_sizes)
        with tempfile.TemporaryDirectory() as td:
            budget_path = _write(td, "prompt-budgets.txt", rendered)
            parsed = psb.parse_budget_file(budget_path)
            self.assertEqual(parsed["shared/rules/_core/x.md"], 42)
            self.assertEqual(parsed["shared/subagents/shared/y.md.j2"], 999)


class MeasureRuleFilesTest(unittest.TestCase):
    def test_measures_real_repo_rule_files(self):
        # Integration smoke test against the actual repo tree — no fixtures,
        # since measure_rule_files() reads from CODEGEN_DIR directly (module-
        # level constant, not injectable). Confirms the walk finds known files
        # and counts lines correctly (non-zero, matches wc -l semantics).
        sizes = psb.measure_rule_files()
        self.assertIn("shared/rules/_core/fail-loud.md", sizes)
        self.assertGreater(sizes["shared/rules/_core/fail-loud.md"], 0)
        # Every discovered file must be under one of the three rule dirs.
        for relpath in sizes:
            self.assertTrue(
                relpath.startswith("shared/rules/_core/")
                or relpath.startswith("shared/rules/roles/")
                or relpath.startswith("shared/rules/stacks/"),
                relpath,
            )


class MainCheckModeTest(unittest.TestCase):
    def test_check_fails_when_file_exceeds_budget(self):
        rule_sizes = {"shared/rules/_core/a.md": 100}
        agent_sizes = {}
        budgets = {"shared/rules/_core/a.md": 50}
        failures = []
        all_sizes = {}
        all_sizes.update(rule_sizes)
        all_sizes.update(agent_sizes)
        for relpath, actual in all_sizes.items():
            budget = budgets.get(relpath)
            if budget is not None and actual > budget:
                failures.append(relpath)
        self.assertEqual(failures, ["shared/rules/_core/a.md"])

    def test_check_passes_when_within_budget(self):
        rule_sizes = {"shared/rules/_core/a.md": 30}
        budgets = {"shared/rules/_core/a.md": 50}
        failures = [r for r, actual in rule_sizes.items() if actual > budgets.get(r, 0)]
        self.assertEqual(failures, [])


class RemedyMessageTest(unittest.TestCase):
    def test_remedy_message_never_names_write_flag(self):
        # Regression guard: the FAILED-path remedy message must never point an
        # agent at --write. prompt-budgets.txt is operator-owned; every agent
        # write path (Edit/Write/MultiEdit, --write, Bash write-vocab) is
        # denied by the prompt-budget-writer-only hook. A reintroduced
        # "--write" token here would silently restore the raise-the-cap
        # escape hatch this gate exists to close.
        self.assertNotIn("--write", psb.REMEDY_MESSAGE)

    def test_remedy_message_names_shrink_or_evict(self):
        self.assertIn("Shrink", psb.REMEDY_MESSAGE)
        self.assertIn("evict", psb.REMEDY_MESSAGE)


if __name__ == "__main__":
    unittest.main()
