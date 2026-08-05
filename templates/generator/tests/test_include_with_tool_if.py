"""Regression test: {% if tool.name %} inside an included fragment must be stripped per-tool.

Before the include-before-if-strip fix, fragments with tool conditionals produced both
branches concatenated (e.g. "CLAUDEOTHER") for every tool. After the fix, claude → "CLAUDE"
and agents → "OTHER".
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import process_template as pt  # noqa: E402


class TestIncludeWithToolIf(unittest.TestCase):
    """Included fragments containing {% if tool.name %} are stripped per-tool."""

    def _setup_tmpdir_with_fragment_and_parent(self, tmpdir):
        """Write a fragment with a tool-conditional and a parent that includes it."""
        shared = Path(tmpdir) / "shared" / "apps"
        shared.mkdir(parents=True)

        fragment = shared / "_frag.md.j2"
        fragment.write_text(
            "{% if tool.name == 'claude' %}CLAUDE{% else %}OTHER{% endif %}\n"
        )

        parent = Path(tmpdir) / "parent.md.j2"
        parent.write_text("BEFORE:{% include 'apps/_frag.md.j2' %}AFTER\n")

        return str(parent)

    def _read_and_strip(self, tmpdir, parent_path, tool_name):
        with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
            with open(parent_path) as f:
                content = f.read()
            return pt._strip_template_blocks(content, tool_name, False)

    def test_claude_renders_claude_branch_from_included_fragment(self):
        """claude tool: fragment's claude-branch rendered, else-branch dropped."""
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = self._setup_tmpdir_with_fragment_and_parent(tmpdir)
            result = self._read_and_strip(tmpdir, parent, "claude")
        self.assertIn("CLAUDE", result)
        self.assertNotIn("OTHER", result)

    def test_agents_renders_else_branch_from_included_fragment(self):
        """agents mode: fragment's else-branch rendered, claude-branch dropped."""
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = self._setup_tmpdir_with_fragment_and_parent(tmpdir)
            result = self._read_and_strip(tmpdir, parent, "agents")
        self.assertIn("OTHER", result)
        self.assertNotIn("CLAUDE", result)

    def test_no_concatenated_branches_for_claude(self):
        """REGRESSION: both branches must NOT appear concatenated (was 'CLAUDEPI' before fix)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = self._setup_tmpdir_with_fragment_and_parent(tmpdir)
            result = self._read_and_strip(tmpdir, parent, "claude")
        self.assertNotIn("CLAUDEOTHER", result)

    def test_no_concatenated_branches_for_agents(self):
        """REGRESSION: both branches must NOT appear concatenated for agents either."""
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = self._setup_tmpdir_with_fragment_and_parent(tmpdir)
            result = self._read_and_strip(tmpdir, parent, "agents")
        self.assertNotIn("CLAUDEOTHER", result)

    def test_surrounding_parent_text_preserved(self):
        """Non-conditional parent text (BEFORE: / AFTER) is preserved around the include."""
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = self._setup_tmpdir_with_fragment_and_parent(tmpdir)
            result = self._read_and_strip(tmpdir, parent, "claude")
        self.assertIn("BEFORE:", result)
        self.assertIn("AFTER", result)


if __name__ == "__main__":
    unittest.main()
