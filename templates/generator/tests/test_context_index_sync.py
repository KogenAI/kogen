"""Unit tests for context_index_sync.py."""

import sys
import tempfile
import unittest
from pathlib import Path

_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import context_index_sync as cis  # noqa: E402

INDEX_TEMPLATE = """# Project Context

## Domain Context Files

| File | Domain | Load when prompt mentions... | Update when changing... |
| --- | --- | --- | --- |
| `context/alpha.md` | Alpha | {alpha} | alpha/ |
| `context/beta.md` | Beta | {beta} | beta/ |

## Always Load

- alpha.md

See `context/alpha.md` for prose cross-references that are NOT table rows.
"""


def _repo(td, alpha_kw, beta_kw, index_alpha, index_beta):
    root = Path(td)
    (root / "context").mkdir()
    (root / "context" / "alpha.md").write_text(
        f"# Alpha\n\n## Trigger Keywords\n\n{alpha_kw}\n\n## Body\n\ntext\n"
    )
    (root / "context" / "beta.md").write_text(
        f"# Beta\n\n## Trigger Keywords\n\n{beta_kw}\n"
    )
    (root / "PROJECT_CONTEXT.md").write_text(
        INDEX_TEMPLATE.format(alpha=index_alpha, beta=index_beta)
    )
    return root


class GenerateTest(unittest.TestCase):
    def test_in_sync_is_a_no_op(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a, b", "c", "a, b", "c")
            _path, original, generated, drifted = cis.generate(root)
            self.assertEqual(drifted, [])
            self.assertEqual(original, generated)

    def test_drifted_cell_is_regenerated_from_the_context_file(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a, b, NEW", "c", "a, b", "c")
            _path, original, generated, drifted = cis.generate(root)
            self.assertEqual(drifted, ["alpha.md"])
            self.assertIn("| a, b, NEW |", generated)
            self.assertNotIn("| a, b |", generated)
            # Only the drifted row moves; everything else is byte-identical.
            self.assertEqual(
                [line for line in original.split("\n") if "beta" in line],
                [line for line in generated.split("\n") if "beta" in line],
            )

    def test_keyword_text_is_copied_verbatim_including_escapes(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, r"stale \_build queue crash, `mcp__x__y`", "c", "old", "c")
            _path, _original, generated, _drifted = cis.generate(root)
            self.assertIn(r"| stale \_build queue crash, `mcp__x__y` |", generated)

    def test_prose_cross_reference_is_not_treated_as_a_row(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a", "c", "a", "c")
            _path, original, generated, _drifted = cis.generate(root)
            self.assertEqual(original, generated)
            self.assertIn("prose cross-references that are NOT table rows", generated)

    def test_row_without_a_context_file_on_disk_raises(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a", "c", "a", "c")
            (root / "context" / "beta.md").unlink()
            with self.assertRaises(cis.SyncError) as ctx:
                cis.generate(root)
            self.assertIn("context/beta.md", str(ctx.exception))

    def test_context_file_without_trigger_keywords_raises(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a", "c", "a", "c")
            (root / "context" / "beta.md").write_text("# Beta\n\n## Body\n\ntext\n")
            with self.assertRaises(cis.SyncError) as ctx:
                cis.generate(root)
            self.assertIn("Trigger Keywords", str(ctx.exception))

    def test_missing_index_doc_raises(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "context").mkdir()
            with self.assertRaises(cis.SyncError):
                cis.generate(root)


class MainTest(unittest.TestCase):
    def test_check_returns_zero_when_in_sync(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a, b", "c", "a, b", "c")
            self.assertEqual(cis.main(["--repo-root", str(root), "--check"]), 0)

    def test_check_returns_one_on_drift(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a, b, NEW", "c", "a, b", "c")
            self.assertEqual(cis.main(["--repo-root", str(root), "--check"]), 1)

    def test_write_makes_check_pass_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as td:
            root = _repo(td, "a, b, NEW", "c", "a, b", "c")
            self.assertEqual(cis.main(["--repo-root", str(root), "--write"]), 0)
            self.assertEqual(cis.main(["--repo-root", str(root), "--check"]), 0)
            after_first = (root / "PROJECT_CONTEXT.md").read_text()
            self.assertEqual(cis.main(["--repo-root", str(root), "--write"]), 0)
            self.assertEqual((root / "PROJECT_CONTEXT.md").read_text(), after_first)


if __name__ == "__main__":
    unittest.main()
