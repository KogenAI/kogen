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


class DerivedCeilingTest(unittest.TestCase):
    """A rule file with no committed row must have a DERIVABLE ceiling.

    Before: "no committed budget row" was a hard fail whose only remedy was
    --write, a command every agent write path to prompt-budgets.txt denies —
    so the role that legitimately added a rule file could not clear the gate
    by any action available to it.
    """

    def test_core_rules_derive_the_strict_style_guide_ceiling(self):
        self.assertEqual(psb.derived_ceiling("shared/rules/_core/foo.md"), 50)

    def test_role_and_stack_rules_derive_the_subagent_ceiling(self):
        self.assertEqual(psb.derived_ceiling("shared/rules/roles/foo.md"), 150)
        self.assertEqual(psb.derived_ceiling("shared/rules/stacks/phoenix/foo.md"), 150)

    def test_unclassified_path_falls_back_to_the_looser_ceiling(self):
        self.assertEqual(psb.derived_ceiling("shared/rules/other/foo.md"), 150)

    def test_derived_ceiling_is_at_or_below_every_style_guide_target(self):
        # The derived ceiling must never be looser than STYLE_GUIDE.md, or a
        # new file would enter under a weaker bar than the guide states.
        self.assertLessEqual(psb.derived_ceiling("shared/rules/_core/x.md"), 50)
        self.assertLessEqual(psb.derived_ceiling("shared/rules/roles/x.md"), 150)


class EffectiveCeilingTest(unittest.TestCase):
    """The one-way ratchet: once a rule file reaches its derived STYLE_GUIDE
    target, hold it there forever so a shrink doesn't quietly regrow back up
    to its grandfathered committed row. A file still over target keeps its
    grandfathered row untouched — nothing green today turns red."""

    def test_file_at_or_under_target_is_capped_to_the_tighter_of_row_and_target(self):
        # bash-discipline.md shrunk to 48 lines (target 50); its grandfathered
        # committed row of 225 must NOT still grant 177 lines of headroom.
        budgets = {"shared/rules/_core/bash-discipline.md": 225}
        self.assertEqual(
            psb.effective_ceiling("shared/rules/_core/bash-discipline.md", 48, budgets),
            50,
        )

    def test_file_still_over_target_keeps_its_grandfathered_row(self):
        budgets = {"shared/rules/stacks/phoenix/testing.md": 247}
        self.assertEqual(
            psb.effective_ceiling("shared/rules/stacks/phoenix/testing.md", 247, budgets),
            247,
        )

    def test_row_already_below_target_is_unaffected_by_the_ratchet(self):
        budgets = {"shared/rules/roles/reviewer.md": 113}
        self.assertEqual(
            psb.effective_ceiling("shared/rules/roles/reviewer.md", 107, budgets),
            113,
        )

    def test_no_committed_row_falls_back_to_derived_ceiling(self):
        self.assertEqual(
            psb.effective_ceiling("shared/rules/_core/new-file.md", 10, {}),
            50,
        )


class IncludeGraphTest(unittest.TestCase):
    """Transitive {% include %} walk against the REAL repo tree — no fixtures,
    since build_include_graph() reads from CODEGEN_DIR directly (module-level
    constant, not injectable), same pattern as MeasureRuleFilesTest above."""

    def test_high_fanout_fragments_reach_all_prompts(self):
        # spike-builder.md.j2 (shape-mode-only) is a 7th prompt that includes
        # only a subset of the universal _core/shared fragments — it does not
        # include fail-fast-required-values.md, session-log.md, or
        # git-readonly.md (no required-value/session-log/git surface in a
        # sandboxed spike). Fragments it DOES include reach 7 prompts now;
        # the rest stay at 6.
        fanout, _reach = psb.build_include_graph()
        seven_of_seven = [
            "shared/rules/_core/bash-discipline.md",
            "shared/rules/_core/fail-loud.md",
            "shared/rules/_core/output-style.md",
            "shared/rules/shared/no-role-spawn.md",
        ]
        six_of_six = [
            "shared/rules/_core/fail-fast-required-values.md",
            "shared/rules/_core/session-log.md",
            "shared/rules/shared/git-readonly.md",
        ]
        for fragment in seven_of_seven:
            self.assertEqual(
                len(fanout.get(fragment, [])), 7, f"{fragment} expected fan-out 7"
            )
        for fragment in six_of_six:
            self.assertEqual(
                len(fanout.get(fragment, [])), 6, f"{fragment} expected fan-out 6"
            )

    def test_reach_is_symmetric_with_fanout(self):
        # Every (fragment -> prompt) pair recorded in fanout must also appear
        # as (prompt -> fragment) in reach, and vice versa.
        fanout, reach = psb.build_include_graph()
        for fragment, prompts in fanout.items():
            for prompt in prompts:
                self.assertIn(
                    fragment,
                    reach.get(prompt, []),
                    f"{fragment} claims to reach {prompt} but reach[{prompt}] disagrees",
                )
        for prompt, fragments in reach.items():
            for fragment in fragments:
                self.assertIn(
                    prompt,
                    fanout.get(fragment, []),
                    f"reach[{prompt}] claims {fragment} but fanout[{fragment}] disagrees",
                )

    def test_every_top_level_prompt_has_a_reach_entry(self):
        _fanout, reach = psb.build_include_graph()
        for relpath in psb._all_top_level_prompts():
            self.assertIn(relpath, reach)


class ReportPathTest(unittest.TestCase):
    """--report --path unit tests against injected (fake) sizes/budgets so the
    projection arithmetic is verified independent of the real repo's current
    numbers (which drift over time)."""

    def _fixture(self):
        rule_sizes = {"shared/rules/_core/x.md": 40}
        agent_sizes = {
            "shared/subagents/phoenix/a.md.j2": 900,
            "shared/subagents/static/b.md.j2": 950,
        }
        budgets = {
            "shared/rules/_core/x.md": 50,
            "shared/subagents/phoenix/a.md.j2": 910,
            "shared/subagents/static/b.md.j2": 960,
        }
        fanout = {
            "shared/rules/_core/x.md": [
                "shared/subagents/phoenix/a.md.j2",
                "shared/subagents/static/b.md.j2",
            ],
        }
        reach = {
            "shared/subagents/phoenix/a.md.j2": ["shared/rules/_core/x.md"],
            "shared/subagents/static/b.md.j2": ["shared/rules/_core/x.md"],
        }
        return rule_sizes, agent_sizes, budgets, fanout, reach

    def test_own_row_reported_in_lines_not_conflated_with_added_bytes(self):
        # A byte delta is never assumed to equal a line delta — the own-row
        # section reports CURRENT state only, never a projected line count
        # from --added-bytes (a byte count). Regression guard for the
        # lines-vs-bytes unit-conflation bug caught during development.
        rule_sizes, agent_sizes, budgets, fanout, reach = self._fixture()
        text, rc = psb.report_path(
            "shared/rules/_core/x.md", 71, rule_sizes, agent_sizes, budgets, fanout, reach
        )
        self.assertEqual(rc, 0)
        self.assertIn("40 lines now, 50 lines budget, 10 lines headroom", text)
        self.assertNotIn("71 lines", text)

    def test_added_bytes_overflows_tightest_reached_prompt(self):
        rule_sizes, agent_sizes, budgets, fanout, reach = self._fixture()
        # a.md.j2: 900/910 -> 10 B headroom. b.md.j2: 950/960 -> 10 B headroom.
        # +15 B overflows both by 5 B.
        text, rc = psb.report_path(
            "shared/rules/_core/x.md", 15, rule_sizes, agent_sizes, budgets, fanout, reach
        )
        self.assertEqual(rc, 0)
        self.assertIn("OVERFLOWS by 5 B", text)
        self.assertIn("evict >= 5 B in this pass", text)

    def test_added_bytes_within_headroom_fits(self):
        rule_sizes, agent_sizes, budgets, fanout, reach = self._fixture()
        text, rc = psb.report_path(
            "shared/rules/_core/x.md", 3, rule_sizes, agent_sizes, budgets, fanout, reach
        )
        self.assertEqual(rc, 0)
        self.assertNotIn("OVERFLOWS", text)
        self.assertIn("fits", text)

    def test_zero_reach_reports_zero_prompts(self):
        rule_sizes = {"shared/rules/_core/orphan.md": 10}
        agent_sizes = {}
        budgets = {}
        fanout = {}
        reach = {}
        text, rc = psb.report_path(
            "shared/rules/_core/orphan.md", 0, rule_sizes, agent_sizes, budgets, fanout, reach
        )
        self.assertEqual(rc, 0)
        self.assertIn("reaches 0 rendered prompts", text)

    def test_path_outside_shared_rules_and_not_an_agent_prompt_exits_2(self):
        rule_sizes, agent_sizes, budgets, fanout, reach = self._fixture()
        text, rc = psb.report_path(
            "lib/not_a_rule.ex", 0, rule_sizes, agent_sizes, budgets, fanout, reach
        )
        self.assertEqual(rc, 2)
        self.assertIn("--path must be a repo-relative path under shared/rules/", text)


class ReportWholeCorpusTest(unittest.TestCase):
    def test_lists_every_prompt_and_fragment_with_headroom(self):
        rule_sizes = {"shared/rules/_core/x.md": 40}
        agent_sizes = {"shared/subagents/phoenix/a.md.j2": 900}
        budgets = {
            "shared/rules/_core/x.md": 50,
            "shared/subagents/phoenix/a.md.j2": 910,
        }
        fanout = {"shared/rules/_core/x.md": ["shared/subagents/phoenix/a.md.j2"]}
        text = psb.report_whole_corpus(rule_sizes, agent_sizes, budgets, fanout)
        self.assertIn("shared/subagents/phoenix/a.md.j2: 900 B / 910 B / 10 B headroom", text)
        self.assertIn("shared/rules/_core/x.md: fan-out 1 -> tightest headroom 10 B", text)


class AttributePromptOverageTest(unittest.TestCase):
    def test_names_heaviest_fragments_by_current_line_count(self):
        reach = {
            "shared/subagents/phoenix/a.md.j2": [
                "shared/rules/_core/small.md",
                "shared/rules/_core/big.md",
            ]
        }
        rule_sizes = {
            "shared/rules/_core/small.md": 10,
            "shared/rules/_core/big.md": 200,
        }
        text = psb.attribute_prompt_overage(
            "shared/subagents/phoenix/a.md.j2", reach, rule_sizes, top_n=2
        )
        self.assertIn("shared/rules/_core/big.md (200 lines)", text)
        # heaviest listed before the lighter one
        self.assertLess(text.index("big.md"), text.index("small.md"))

    def test_no_reach_returns_empty_string(self):
        text = psb.attribute_prompt_overage("shared/subagents/phoenix/nope.md.j2", {}, {})
        self.assertEqual(text, "")


class CheckModeAddedBytesValidationTest(unittest.TestCase):
    def test_added_bytes_without_path_is_rejected_at_argv_level(self):
        # Regression guard for the CLI usage contract: --added-bytes only
        # means something paired with --path. Exercised via the module's
        # own argparse wiring by calling main() with sys.argv patched.
        import io
        import contextlib

        old_argv = sys.argv
        try:
            sys.argv = ["prompt_size_budget.py", "--report", "--added-bytes", "5"]
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = psb.main()
            self.assertEqual(rc, 2)
            self.assertIn("--added-bytes requires --path", buf.getvalue())
        finally:
            sys.argv = old_argv

    def test_negative_added_bytes_is_rejected(self):
        import io
        import contextlib

        old_argv = sys.argv
        try:
            sys.argv = [
                "prompt_size_budget.py",
                "--report",
                "--path",
                "shared/rules/_core/fail-loud.md",
                "--added-bytes",
                "-1",
            ]
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = psb.main()
            self.assertEqual(rc, 2)
            self.assertIn("non-negative integer", buf.getvalue())
        finally:
            sys.argv = old_argv
