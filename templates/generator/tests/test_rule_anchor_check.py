"""Unit tests for rule_anchor_check.py."""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import rule_anchor_check as rac  # noqa: E402

REGISTRY_TEMPLATE = """
seams:
  - id: fixture-anchor
    declares: "shared/rules/roles/fixture.md § Fixture Section"
    reflects: "some enforcer that reads the anchor text"
    guard: rule-anchor-check
    guard_time: make-test
    pattern: checked-mirror
"""

FIXTURE_TABLE = {
    "fixture-anchor": (
        "shared/rules/roles/fixture.md",
        "ANCHOR TEXT HERE",
    ),
}


def _repo(td, rule_body, registry_text=REGISTRY_TEMPLATE):
    root = Path(td)
    (root / "shared" / "rules" / "roles").mkdir(parents=True)
    (root / "shared" / "rules" / "roles" / "fixture.md").write_text(rule_body)
    (root / "shared" / "enforcement").mkdir(parents=True)
    (root / "shared" / "enforcement" / "seam-registry.yaml").write_text(registry_text)
    return root


class CheckAnchorsTest(unittest.TestCase):
    def test_anchor_present_is_found(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\n## Fixture Section\n\nANCHOR TEXT HERE lives here.\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                results = rac.check_anchors(root)
            self.assertEqual(results, [("fixture-anchor", "shared/rules/roles/fixture.md", "ANCHOR TEXT HERE", True)])

    def test_anchor_deleted_is_missing(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nNo anchor here anymore.\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                results = rac.check_anchors(root)
            self.assertEqual(results, [("fixture-anchor", "shared/rules/roles/fixture.md", "ANCHOR TEXT HERE", False)])

    def test_anchor_reworded_around_survives(self):
        # Rewording prose AROUND the anchor substring is fine; only the
        # registered substring itself must survive verbatim.
        with tempfile.TemporaryDirectory() as td:
            root = _repo(
                td,
                "# Fixture\n\nCompletely different intro paragraph now.\n\n"
                "## Fixture Section\n\nANCHOR TEXT HERE, restated with new context.\n",
            )
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                results = rac.check_anchors(root)
            self.assertTrue(results[0][3])

    def test_missing_rule_file_is_missing(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nANCHOR TEXT HERE\n")
            (root / "shared" / "rules" / "roles" / "fixture.md").unlink()
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                results = rac.check_anchors(root)
            self.assertFalse(results[0][3])


class RegistryCoverageTest(unittest.TestCase):
    def test_in_sync_table_and_registry_produce_no_problems(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nANCHOR TEXT HERE\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                problems = rac.check_registry_coverage(root)
            self.assertEqual(problems, [])

    def test_registry_row_with_no_table_entry_is_a_problem(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nsome text\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, {}, clear=True):
                problems = rac.check_registry_coverage(root)
            self.assertEqual(len(problems), 1)
            self.assertIn("fixture-anchor", problems[0])
            self.assertIn("no ANCHOR_TEXT entry", problems[0])

    def test_table_entry_with_no_registry_row_is_a_problem(self):
        registry_text = "seams:\n  - id: unrelated\n    declares: x\n    reflects: y\n    guard: GAP\n    guard_time: make-test\n    pattern: checked-mirror\n    gap_rationale: because\n"
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nANCHOR TEXT HERE\n", registry_text=registry_text)
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                problems = rac.check_registry_coverage(root)
            self.assertEqual(len(problems), 1)
            self.assertIn("fixture-anchor", problems[0])
            self.assertIn("registry.yaml has no matching row", problems[0])

    def test_missing_registry_file_raises(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with self.assertRaises(rac.AnchorError):
                rac.check_registry_coverage(root)


class MainTest(unittest.TestCase):
    def test_check_returns_zero_when_all_anchors_present(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nANCHOR TEXT HERE\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                rc = rac.main(["--repo-root", str(root), "--check"])
            self.assertEqual(rc, 0)

    def test_check_returns_one_when_an_anchor_is_missing(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nno anchor.\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                rc = rac.main(["--repo-root", str(root), "--check"])
            self.assertEqual(rc, 1)

    def test_report_always_returns_zero(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "# Fixture\n\nno anchor.\n")
            with mock.patch.dict(rac.ANCHOR_TEXT, FIXTURE_TABLE, clear=True):
                rc = rac.main(["--repo-root", str(root), "--report"])
            self.assertEqual(rc, 0)

    def test_real_repo_check_passes_against_committed_registry_and_rules(self):
        # No mock.patch here — exercises the real ANCHOR_TEXT table against
        # this repo's own committed rule files, as `make rule-anchor-check`
        # would run it. This is the live confirmation that the six anchors
        # registered by this pitch actually resolve at HEAD.
        repo_root = Path(__file__).parent.parent.parent.parent
        rc = rac.main(["--repo-root", str(repo_root), "--check"])
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
