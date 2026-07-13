"""Unit tests for process_template.py — cover resolve_include, process_includes_recursively,
_strip_template_blocks, and process_template (model/effort rewrite).
"""

import os
import sys
import tempfile
import textwrap
import unittest
from io import StringIO
from pathlib import Path
from unittest.mock import patch

# Ensure the generator dir is importable regardless of cwd.
_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import process_template as pt  # noqa: E402


class TestResolveInclude(unittest.TestCase):
    """resolve_include — CODEGEN_DIR set, fallback auto-detect, missing raises."""

    def test_codegen_dir_env_lookup(self):
        """CODEGEN_DIR set → file found under CODEGEN_DIR/shared/."""
        with tempfile.TemporaryDirectory() as tmpdir:
            shared = Path(tmpdir) / "shared"
            shared.mkdir()
            target = shared / "my_include.md"
            target.write_text("hello from include")
            with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
                result = pt.resolve_include("my_include.md")
            self.assertEqual(result, "hello from include")

    def test_codegen_dir_env_missing_file_falls_through_to_autodetect(self):
        """CODEGEN_DIR set but file absent → falls through to auto-detect path.

        Auto-detect computes codegen root as two levels up from process_template.py.
        We can't control the real repo's shared/ in a unit test, so we just assert
        that a FileNotFoundError is raised (file genuinely absent everywhere).
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            # tmpdir has no shared/ subdir → CODEGEN_DIR lookup misses
            with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
                with self.assertRaises(FileNotFoundError):
                    pt.resolve_include("definitely_not_there_xyz.md")

    def test_codegen_dir_unset_fallback_autodetect_missing(self):
        """CODEGEN_DIR absent → auto-detect fires; missing file raises FileNotFoundError."""
        env_without_codegen = {k: v for k, v in os.environ.items() if k != "CODEGEN_DIR"}
        with patch.dict(os.environ, env_without_codegen, clear=True):
            with self.assertRaises(FileNotFoundError):
                pt.resolve_include("no_such_file_abc123.md")

    def test_codegen_dir_env_file_content_returned_verbatim(self):
        """Content of the included file is returned as-is (no stripping)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            shared = Path(tmpdir) / "shared"
            shared.mkdir()
            content = "line1\nline2\n"
            (shared / "inc.md").write_text(content)
            with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
                result = pt.resolve_include("inc.md")
            self.assertEqual(result, content)


class TestProcessIncludesRecursively(unittest.TestCase):
    """process_includes_recursively — depth cap, nested resolution, no-op passthrough."""

    def test_no_include_passthrough(self):
        """Content with no include directives is returned unchanged."""
        content = "Just some text\nNo includes here\n"
        result = pt.process_includes_recursively(content)
        self.assertEqual(result, content)

    def test_depth_cap_returns_content_unchanged(self):
        """Calling with depth >= MAX_DEPTH (10) returns content unchanged."""
        content = "{% include 'something.md' %}"
        # depth=10 equals MAX_DEPTH — should return as-is without resolving
        result = pt.process_includes_recursively(content, depth=10)
        self.assertEqual(result, content)

    def test_nested_include_resolved(self):
        """Nested includes: outer includes inner, inner has no includes."""
        with tempfile.TemporaryDirectory() as tmpdir:
            shared = Path(tmpdir) / "shared"
            shared.mkdir()
            inner = shared / "inner.md"
            inner.write_text("inner content")
            outer = shared / "outer.md"
            outer.write_text("{% include 'inner.md' %}")
            with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
                result = pt.process_includes_recursively("{% include 'outer.md' %}")
            self.assertIn("inner content", result)

    def test_single_include_resolved(self):
        """Single include directive is resolved to file content."""
        with tempfile.TemporaryDirectory() as tmpdir:
            shared = Path(tmpdir) / "shared"
            shared.mkdir()
            (shared / "greet.md").write_text("Hello World")
            with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
                result = pt.process_includes_recursively("before\n{% include 'greet.md' %}\nafter")
            self.assertIn("Hello World", result)
            self.assertIn("before", result)
            self.assertIn("after", result)

    def test_include_with_double_quotes(self):
        """Include directive using double quotes is resolved."""
        with tempfile.TemporaryDirectory() as tmpdir:
            shared = Path(tmpdir) / "shared"
            shared.mkdir()
            (shared / "file.md").write_text("dq content")
            with patch.dict(os.environ, {"CODEGEN_DIR": tmpdir}):
                result = pt.process_includes_recursively('{% include "file.md" %}')
            self.assertIn("dq content", result)


class TestStripTemplateBlocks(unittest.TestCase):
    """_strip_template_blocks — claude/pi branch selection, frontmatter, invalid tool_name."""

    def test_claude_keeps_claude_branch_drops_else(self):
        content = "{% if tool.name == 'claude' %}CLAUDE_CONTENT{% else %}PI_CONTENT{% endif %}"
        result = pt._strip_template_blocks(content, "claude", False)
        self.assertIn("CLAUDE_CONTENT", result)
        self.assertNotIn("PI_CONTENT", result)

    def test_pi_keeps_else_branch_drops_claude(self):
        content = "{% if tool.name == 'claude' %}CLAUDE_CONTENT{% else %}PI_CONTENT{% endif %}"
        result = pt._strip_template_blocks(content, "pi", False)
        self.assertIn("PI_CONTENT", result)
        self.assertNotIn("CLAUDE_CONTENT", result)

    def test_claude_simple_if_no_else_kept(self):
        content = "{% if tool.name == 'claude' %}ONLY_CLAUDE{% endif %}"
        result = pt._strip_template_blocks(content, "claude", False)
        self.assertIn("ONLY_CLAUDE", result)

    def test_pi_simple_if_no_else_dropped(self):
        content = "{% if tool.name == 'claude' %}ONLY_CLAUDE{% endif %}"
        result = pt._strip_template_blocks(content, "pi", False)
        self.assertNotIn("ONLY_CLAUDE", result)
        # block removed → not just tags stripped, whole block gone
        self.assertEqual(result.strip(), "")

    def test_yaml_frontmatter_true_keeps_content(self):
        content = "{% if tool.yaml_frontmatter %}---\ntitle: test\n---\n{% endif %}body"
        result = pt._strip_template_blocks(content, "claude", True)
        self.assertIn("title: test", result)
        self.assertIn("body", result)

    def test_yaml_frontmatter_false_drops_block(self):
        content = "{% if tool.yaml_frontmatter %}---\ntitle: test\n---\n{% endif %}body"
        result = pt._strip_template_blocks(content, "claude", False)
        self.assertNotIn("title: test", result)
        self.assertIn("body", result)

    def test_invalid_tool_name_raises_value_error(self):
        with self.assertRaises(ValueError) as ctx:
            pt._strip_template_blocks("content", "invalid_tool", False)
        self.assertIn("invalid_tool", str(ctx.exception))

    def test_tool_name_variable_substituted(self):
        content = "tool is {{ tool.name }}"
        result = pt._strip_template_blocks(content, "claude", False)
        self.assertIn("tool is claude", result)

    def test_multiline_claude_branch(self):
        content = "{% if tool.name == 'claude' %}\nline1\nline2\n{% else %}\nother\n{% endif %}"
        result = pt._strip_template_blocks(content, "claude", False)
        self.assertIn("line1", result)
        self.assertIn("line2", result)
        self.assertNotIn("other", result)


class TestProcessTemplate(unittest.TestCase):
    """process_template — model+effort rewrite, pi mode untouched, role absent no-op, yaml absent no-op."""

    def _make_template(self, tmpdir, name, content):
        p = Path(tmpdir) / name
        p.write_text(content)
        return str(p)

    def _make_config(self, tmpdir, content):
        p = Path(tmpdir) / "config.yaml"
        p.write_text(content)
        return str(p)

    TEMPLATE_CONTENT = textwrap.dedent("""\
        ---
        name: planner-phoenix
        model: sonnet
        ---
        Body text here.
    """)

    CONFIG_YAML = textwrap.dedent("""\
        harness:
          planner-phoenix:
            claude: { model: opus, effort: high }
    """)

    def test_claude_mode_rewrites_model_and_effort(self):
        """claude mode with config → model line rewritten, effort injected."""
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", self.TEMPLATE_CONTENT)
            config = self._make_config(tmpdir, self.CONFIG_YAML)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "claude", False, config)
                output = mock_out.getvalue()
            self.assertIn("model: opus", output)
            self.assertIn("effort: high", output)
            self.assertNotIn("model: sonnet", output)

    def test_pi_mode_never_rewrites(self):
        """pi mode: model line is never rewritten regardless of config."""
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", self.TEMPLATE_CONTENT)
            config = self._make_config(tmpdir, self.CONFIG_YAML)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "pi", False, config)
                output = mock_out.getvalue()
            # pi mode: model: sonnet left as-is (no config rewrite)
            self.assertIn("model: sonnet", output)

    def test_role_absent_from_config_raises(self):
        """Role missing from harness in config, but template has a model: line → fail loud."""
        config_yaml = textwrap.dedent("""\
            harness:
              other-role:
                claude: { model: opus, effort: high }
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", self.TEMPLATE_CONTENT)
            config = self._make_config(tmpdir, config_yaml)
            with self.assertRaises(SystemExit) as ctx:
                pt.process_template(template, "claude", False, config)
            self.assertIn("planner-phoenix", str(ctx.exception))

    def test_role_cfg_missing_model_or_effort_raises(self):
        """Role present but claude cfg missing model/effort → fail loud."""
        config_yaml = textwrap.dedent("""\
            harness:
              planner-phoenix:
                claude: { model: opus }
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", self.TEMPLATE_CONTENT)
            config = self._make_config(tmpdir, config_yaml)
            with self.assertRaises(SystemExit) as ctx:
                pt.process_template(template, "claude", False, config)
            self.assertIn("model/effort", str(ctx.exception))

    def test_no_model_line_template_skips_role_requirement(self):
        """Template with no model: frontmatter line (e.g. a slash command) is not a role — no-op passthrough."""
        command_content = textwrap.dedent("""\
            ---
            description: some command
            ---
            Body text here.
        """)
        config_yaml = textwrap.dedent("""\
            harness:
              other-role:
                claude: { model: opus, effort: high }
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "poke-holes.md.j2", command_content)
            config = self._make_config(tmpdir, config_yaml)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "claude", True, config)
                output = mock_out.getvalue()
            self.assertIn("description: some command", output)

    def test_missing_yaml_module_raises(self):
        """yaml import failure → SystemExit with install hint (fail-loud)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", self.TEMPLATE_CONTENT)
            config = self._make_config(tmpdir, self.CONFIG_YAML)
            with patch.dict(sys.modules, {"yaml": None}):
                with self.assertRaises(SystemExit) as ctx:
                    pt.process_template(template, "claude", False, config)
            self.assertIn("pyyaml", str(ctx.exception).lower())

    def test_no_config_no_rewrite(self):
        """config_yaml=None → model line stays as-is."""
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", self.TEMPLATE_CONTENT)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "claude", False, None)
                output = mock_out.getvalue()
            self.assertIn("model: sonnet", output)


class PiToolMapTests(unittest.TestCase):
    """pi frontmatter tools: line rewrite via config.yaml tools.pi.tool_map."""

    def _make_template(self, tmpdir, name, content):
        p = Path(tmpdir) / name
        p.write_text(content)
        return str(p)

    def _make_config(self, tmpdir, content):
        p = Path(tmpdir) / "config.yaml"
        p.write_text(content)
        return str(p)

    TOOL_MAP_CONFIG = textwrap.dedent("""\
        tools:
          pi:
            tool_map:
              Bash: bash
              Edit: edit
              Glob: find
              Grep: grep
              MultiEdit: edit
              Read: read
              Write: write
        harness:
          planner-phoenix:
            claude: { model: opus, effort: high }
    """)

    def test_pi_tools_line_mapped(self):
        """claude tool names in tools: line → pi tool names."""
        content = textwrap.dedent("""\
            ---
            name: planner-phoenix
            model: sonnet
            tools: Bash, Edit, Glob, Grep, Read
            ---
            Body text here.
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", content)
            config = self._make_config(tmpdir, self.TOOL_MAP_CONFIG)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "pi", True, config)
                output = mock_out.getvalue()
            self.assertIn("tools: bash, edit, find, grep, read", output)

    def test_pi_tools_dedupes_edit(self):
        """Edit + MultiEdit both map to edit -> single entry, not duplicated."""
        content = textwrap.dedent("""\
            ---
            name: developer-phoenix-backend
            model: sonnet
            tools: Edit, MultiEdit
            ---
            Body text here.
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "developer-phoenix-backend.md.j2", content)
            config = self._make_config(tmpdir, self.TOOL_MAP_CONFIG)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "pi", True, config)
                output = mock_out.getvalue()
            self.assertIn("tools: edit", output)
            self.assertNotIn("tools: edit, edit", output)

    def test_pi_tools_preserves_order(self):
        """Mapped tool order matches the source order."""
        content = textwrap.dedent("""\
            ---
            name: committer
            model: haiku
            tools: Write, Bash
            ---
            Body text here.
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "committer.md.j2", content)
            config = self._make_config(tmpdir, self.TOOL_MAP_CONFIG)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "pi", True, config)
                output = mock_out.getvalue()
            self.assertIn("tools: write, bash", output)

    def test_pi_unmapped_tool_aborts(self):
        """A claude tool with no tool_map entry aborts generation, naming the tool."""
        content = textwrap.dedent("""\
            ---
            name: debug
            model: opus
            tools: Skill
            ---
            Body text here.
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "debug.md.j2", content)
            config = self._make_config(tmpdir, self.TOOL_MAP_CONFIG)
            with self.assertRaises(SystemExit) as ctx:
                pt.process_template(template, "pi", True, config)
            self.assertIn("Skill", str(ctx.exception))

    def test_pi_frontmatter_without_tools_line_untouched(self):
        """description:-only frontmatter (slash-command shape) renders unchanged."""
        content = textwrap.dedent("""\
            ---
            description: some command
            ---
            Body text here.
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "poke-holes.md.j2", content)
            config = self._make_config(tmpdir, self.TOOL_MAP_CONFIG)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "pi", True, config)
                output = mock_out.getvalue()
            self.assertIn("description: some command", output)
            self.assertNotIn("tools:", output)

    def test_claude_render_unaffected_by_tool_map(self):
        """claude render of the same content still emits claude tool names verbatim."""
        content = textwrap.dedent("""\
            ---
            name: planner-phoenix
            model: sonnet
            tools: Bash, Edit, Glob, Grep, Read
            ---
            Body text here.
        """)
        config_yaml = textwrap.dedent("""\
            tools:
              pi:
                tool_map:
                  Bash: bash
            harness:
              planner-phoenix:
                claude: { model: opus, effort: high }
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "planner-phoenix.md.j2", content)
            config = self._make_config(tmpdir, config_yaml)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "claude", True, config)
                output = mock_out.getvalue()
            self.assertIn("tools: Bash, Edit, Glob, Grep, Read", output)

    def test_pi_body_horizontal_rule_survives(self):
        """A literal '---' line inside the prompt body is not treated as a frontmatter delimiter."""
        content = textwrap.dedent("""\
            ---
            name: committer
            model: haiku
            tools: Write
            ---
            Above the rule.

            ---

            Below the rule.
        """)
        with tempfile.TemporaryDirectory() as tmpdir:
            template = self._make_template(tmpdir, "committer.md.j2", content)
            config = self._make_config(tmpdir, self.TOOL_MAP_CONFIG)
            with patch("sys.stdout", new_callable=StringIO) as mock_out:
                pt.process_template(template, "pi", True, config)
                output = mock_out.getvalue()
            self.assertIn("tools: write", output)
            self.assertIn("Above the rule.", output)
            self.assertIn("Below the rule.", output)


if __name__ == "__main__":
    unittest.main()
