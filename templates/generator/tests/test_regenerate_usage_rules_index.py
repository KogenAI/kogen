"""Unit tests for regenerate_usage_rules_index.py."""

import sys
import tempfile
import unittest
from pathlib import Path

_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import regenerate_usage_rules_index as rui  # noqa: E402


def _write(dirpath, name, content=""):
    p = Path(dirpath) / name
    p.write_text(content)
    return p


class VersionKeyTest(unittest.TestCase):
    def test_numeric_ordering(self):
        self.assertGreater(rui.version_key("1.8.8"), rui.version_key("1.8.7"))
        self.assertGreater(rui.version_key("1.10.0"), rui.version_key("1.9.0"))
        self.assertGreater(rui.version_key("2.20.3"), rui.version_key("2.20.1"))

    def test_git_sha_sorts_after_numeric(self):
        self.assertGreater(rui.version_key("git-00bdc9d"), rui.version_key("1.8.8"))


class ScanCorpusTest(unittest.TestCase):
    def test_scans_main_and_topic_files(self):
        with tempfile.TemporaryDirectory() as td:
            _write(td, "phoenix-1.8.4.md")
            _write(td, "phoenix-1.8.4-routing.md")
            _write(td, "phoenix-1.8.8.md")
            _write(td, "phoenix-1.8.8-routing.md")
            _write(td, "INDEX.md")  # excluded non-dep file
            deps = rui.scan_corpus(Path(td))
            self.assertIn("phoenix", deps)
            self.assertEqual(set(deps["phoenix"].keys()), {"1.8.4", "1.8.8"})
            self.assertEqual(
                set(deps["phoenix"]["1.8.8"]),
                {"phoenix-1.8.8.md", "phoenix-1.8.8-routing.md"},
            )

    def test_excludes_non_dep_files(self):
        with tempfile.TemporaryDirectory() as td:
            _write(td, "forms.md")
            _write(td, "lifecycle.md")
            deps = rui.scan_corpus(Path(td))
            self.assertEqual(deps, {})


class MaxVersionFilesTest(unittest.TestCase):
    def test_returns_highest_version(self):
        versions = {
            "1.8.4": ["phoenix-1.8.4.md", "phoenix-1.8.4-routing.md"],
            "1.8.8": ["phoenix-1.8.8.md", "phoenix-1.8.8-routing.md"],
        }
        max_v, files = rui.max_version_files(versions)
        self.assertEqual(max_v, "1.8.8")
        self.assertEqual(files, ["phoenix-1.8.8-routing.md", "phoenix-1.8.8.md"])


class ParseExistingIndexTest(unittest.TestCase):
    def test_parses_use_when_and_citations(self):
        with tempfile.TemporaryDirectory() as td:
            index = _write(
                td,
                "INDEX.md",
                "# Usage Rules Index\n\n"
                "## phoenix\n\n"
                "Use when: writing controllers.\n\n"
                "- `phoenix-1.8.4.md`\n"
                "- `phoenix-1.8.4-routing.md`\n",
            )
            deps = rui.parse_existing_index(index)
            self.assertEqual(
                deps["phoenix"]["use_when"], "Use when: writing controllers."
            )
            self.assertEqual(
                deps["phoenix"]["cited_files"],
                ["phoenix-1.8.4.md", "phoenix-1.8.4-routing.md"],
            )

    def test_missing_file_returns_empty(self):
        deps = rui.parse_existing_index(Path("/nonexistent/INDEX.md"))
        self.assertEqual(deps, {})


class RenderIndexTest(unittest.TestCase):
    def test_updates_citation_to_max_version(self):
        tracked = {
            "phoenix": {
                "use_when": "Use when: writing controllers.",
                "cited_files": ["phoenix-1.8.4.md"],
            }
        }
        corpus = {
            "phoenix": {
                "1.8.4": ["phoenix-1.8.4.md"],
                "1.8.8": ["phoenix-1.8.8.md", "phoenix-1.8.8-routing.md"],
            }
        }
        orphaned = []
        rendered = rui.render_index(tracked, corpus, orphaned)
        self.assertIn("phoenix-1.8.8.md", rendered)
        self.assertNotIn("phoenix-1.8.4.md", rendered)
        self.assertIn("Use when: writing controllers.", rendered)
        self.assertEqual(orphaned, [])

    def test_never_adds_untracked_dep(self):
        tracked = {"phoenix": {"use_when": "Use when: X.", "cited_files": []}}
        corpus = {
            "phoenix": {"1.8.8": ["phoenix-1.8.8.md"]},
            "ash": {"3.7.6": ["ash-3.7.6.md"]},
        }
        rendered = rui.render_index(tracked, corpus, [])
        self.assertNotIn("## ash", rendered)
        self.assertIn("## phoenix", rendered)

    def test_orphaned_tracked_dep_keeps_existing_citations(self):
        tracked = {
            "gone_dep": {
                "use_when": "Use when: something.",
                "cited_files": ["gone_dep-1.0.0.md"],
            }
        }
        corpus = {}
        orphaned = []
        rendered = rui.render_index(tracked, corpus, orphaned)
        self.assertIn("gone_dep-1.0.0.md", rendered)
        self.assertEqual(orphaned, ["gone_dep"])


class MainCheckModeTest(unittest.TestCase):
    def test_check_passes_when_index_matches_corpus(self):
        with tempfile.TemporaryDirectory() as td:
            _write(td, "phoenix-1.8.8.md")
            index_path = _write(td, "INDEX.md", "## phoenix\n\nUse when: X.\n\n- `phoenix-1.8.8.md`\n")
            # First regeneration establishes the canonical header + body.
            tracked = rui.parse_existing_index(index_path)
            corpus = rui.scan_corpus(Path(td))
            rendered = rui.render_index(tracked, corpus, [])
            index_path.write_text(rendered)

            # Second regeneration against the now-canonical file must be a no-op.
            tracked2 = rui.parse_existing_index(index_path)
            rendered2 = rui.render_index(tracked2, corpus, [])
            current = index_path.read_text()
            self.assertEqual(current.strip(), rendered2.strip())

    def test_check_fails_when_index_stale(self):
        with tempfile.TemporaryDirectory() as td:
            _write(td, "phoenix-1.8.8.md")
            _write(
                td,
                "INDEX.md",
                "# Usage Rules Index\n\n"
                "## phoenix\n\n"
                "Use when: X.\n\n"
                "- `phoenix-1.8.4.md`\n",
            )
            tracked = rui.parse_existing_index(Path(td) / "INDEX.md")
            corpus = rui.scan_corpus(Path(td))
            rendered = rui.render_index(tracked, corpus, [])
            current = (Path(td) / "INDEX.md").read_text()
            self.assertNotEqual(current.strip(), rendered.strip())


if __name__ == "__main__":
    unittest.main()
