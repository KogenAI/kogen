"""Unit tests for hook_registrations.py — cover parse_manifest, validate_signal,
validate_role_match, dumps_compact, group_by_event, build_hook_entry.
"""

import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path
from unittest.mock import patch

# Ensure the generator dir is importable regardless of cwd.
_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import hook_registrations as hr  # noqa: E402

# ── helpers ─────────────────────────────────────────────────────────────────

MINIMAL_MANIFEST = """\
#!/usr/bin/env bash
# HOOK-MANIFEST:
#   event: PreToolUse
#   matcher: Bash
#   surface: user_global
#   signal: AGENT_TYPE
#   role: developer-phoenix-backend
[ "$AGENT_TYPE" = "developer-phoenix-backend" ] || exit 0
"""


def _write_sh(tmpdir, name, content):
    p = Path(tmpdir) / name
    p.write_text(content)
    return p


# ── TestParseManifest ────────────────────────────────────────────────────────

class TestParseManifest(unittest.TestCase):

    def test_valid_manifest_returns_dict(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "my-hook.sh", MINIMAL_MANIFEST)
            result = hr.parse_manifest(p)
        self.assertEqual(result["event"], "PreToolUse")
        self.assertEqual(result["matcher"], "Bash")
        self.assertEqual(result["surface"], "user_global")
        self.assertEqual(result["signal"], "AGENT_TYPE")
        self.assertEqual(result["role"], "developer-phoenix-backend")
        self.assertEqual(result["filename"], "my-hook.sh")
        self.assertIsNone(result["harnesses"])  # absent → None (ships everywhere)

    def test_missing_required_field_exits_1(self):
        content = """\
#!/usr/bin/env bash
# HOOK-MANIFEST:
#   event: PreToolUse
#   matcher: Bash
#   surface: user_global
#   signal: AGENT_TYPE
"""
        # role is missing → should exit 1
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.parse_manifest(p)
        self.assertEqual(ctx.exception.code, 1)

    def test_invalid_surface_exits_1(self):
        content = MINIMAL_MANIFEST.replace("surface: user_global", "surface: bad_surface")
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.parse_manifest(p)
        self.assertEqual(ctx.exception.code, 1)

    def test_invalid_signal_exits_1(self):
        content = MINIMAL_MANIFEST.replace("signal: AGENT_TYPE", "signal: UNKNOWN_SIGNAL")
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.parse_manifest(p)
        self.assertEqual(ctx.exception.code, 1)

    def test_harnesses_all_returns_none(self):
        content = MINIMAL_MANIFEST + "#   harnesses: all\n"
        # Insert harnesses field into the manifest header
        content = MINIMAL_MANIFEST.replace(
            "#   role: developer-phoenix-backend",
            "#   role: developer-phoenix-backend\n#   harnesses: all",
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "h.sh", content)
            result = hr.parse_manifest(p)
        self.assertIsNone(result["harnesses"])

    def test_harnesses_explicit_token_returns_list(self):
        content = MINIMAL_MANIFEST.replace(
            "#   role: developer-phoenix-backend",
            "#   role: developer-phoenix-backend\n#   harnesses: claude_code",
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "h.sh", content)
            result = hr.parse_manifest(p)
        self.assertEqual(result["harnesses"], ["claude_code"])

    def test_invalid_harness_token_exits_1(self):
        content = MINIMAL_MANIFEST.replace(
            "#   role: developer-phoenix-backend",
            "#   role: developer-phoenix-backend\n#   harnesses: invalid_harness",
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "h.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.parse_manifest(p)
        self.assertEqual(ctx.exception.code, 1)

    def test_timeout_field_parsed_as_int(self):
        """parse_manifest coerces # timeout: 360 to int 360."""
        content = MINIMAL_MANIFEST.replace(
            "#   role: developer-phoenix-backend",
            "#   role: developer-phoenix-backend\n#   timeout: 360",
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "h.sh", content)
            result = hr.parse_manifest(p)
        self.assertEqual(result["timeout"], 360)
        self.assertIsInstance(result["timeout"], int)

    def test_non_integer_timeout_exits_1(self):
        """parse_manifest exits 1 when # timeout: is not a valid integer."""
        content = MINIMAL_MANIFEST.replace(
            "#   role: developer-phoenix-backend",
            "#   role: developer-phoenix-backend\n#   timeout: abc",
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "h.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.parse_manifest(p)
        self.assertEqual(ctx.exception.code, 1)

    def test_timeout_absent_means_no_key(self):
        """parse_manifest must not inject a timeout key when header has none."""
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "h.sh", MINIMAL_MANIFEST)
            result = hr.parse_manifest(p)
        self.assertNotIn("timeout", result)


# ── TestValidateSignal ───────────────────────────────────────────────────────

class TestValidateSignal(unittest.TestCase):

    def _manifest(self, signal):
        return {"signal": signal, "role": "*"}

    def test_agent_type_present_passes(self):
        content = '[ "$AGENT_TYPE" = "something" ] || exit 0\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            # Should not raise
            hr.validate_signal(p, self._manifest("AGENT_TYPE"))

    def test_agent_type_absent_exits_1(self):
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.validate_signal(p, self._manifest("AGENT_TYPE"))
        self.assertEqual(ctx.exception.code, 1)

    def test_claude_role_present_passes(self):
        content = '[ "$CLAUDE_ROLE" = "something" ] || exit 0\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_signal(p, self._manifest("CLAUDE_ROLE"))

    def test_claude_role_absent_exits_1(self):
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.validate_signal(p, self._manifest("CLAUDE_ROLE"))
        self.assertEqual(ctx.exception.code, 1)

    def test_claude_role_family_needs_resolve_role(self):
        content = 'resolve_role\necho "$role"\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_signal(p, self._manifest("CLAUDE_ROLE_FAMILY"))

    def test_claude_role_family_absent_exits_1(self):
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.validate_signal(p, self._manifest("CLAUDE_ROLE_FAMILY"))
        self.assertEqual(ctx.exception.code, 1)

    def test_signal_none_skips(self):
        # none signal: no check regardless of body
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            # Should not raise
            hr.validate_signal(p, self._manifest("none"))

    def test_require_inspector_satisfies_agent_type(self):
        """require_inspector_agent_type counts as AGENT_TYPE reference."""
        content = "require_inspector_agent_type\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_signal(p, self._manifest("AGENT_TYPE"))


# ── TestValidateRoleMatch ────────────────────────────────────────────────────

class TestValidateRoleMatch(unittest.TestCase):

    def test_literal_role_eq_check_passes(self):
        manifest = {"signal": "AGENT_TYPE", "role": "developer-phoenix-backend"}
        content = '[ "$AGENT_TYPE" = "developer-phoenix-backend" ] || exit 0\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_role_match(p, manifest)

    def test_literal_role_mismatch_exits_1(self):
        manifest = {"signal": "AGENT_TYPE", "role": "developer-phoenix-backend"}
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "bad.sh", content)
            with self.assertRaises(SystemExit) as ctx:
                with patch("sys.stderr", new_callable=io.StringIO):
                    hr.validate_role_match(p, manifest)
        self.assertEqual(ctx.exception.code, 1)

    def test_glob_role_passes_with_case(self):
        manifest = {"signal": "AGENT_TYPE", "role": "planner-*"}
        content = 'case "$AGENT_TYPE" in\nplanner-*) ;;\nesac\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_role_match(p, manifest)

    def test_wildcard_role_skips_check(self):
        manifest = {"signal": "AGENT_TYPE", "role": "*"}
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            # Should not raise — wildcard skips body check
            hr.validate_role_match(p, manifest)

    def test_multi_value_role_passes(self):
        manifest = {"signal": "AGENT_TYPE", "role": "developer-phoenix-backend | developer-phoenix-frontend"}
        content = 'case "$AGENT_TYPE" in\ndeveloper-phoenix-backend) ;;\ndeveloper-phoenix-frontend) ;;\nesac\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_role_match(p, manifest)

    def test_non_agent_type_signal_skips(self):
        """validate_role_match only checks AGENT_TYPE signal hooks."""
        manifest = {"signal": "CLAUDE_ROLE", "role": "developer-phoenix-backend"}
        content = "echo hello\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            # Should not raise — CLAUDE_ROLE signal not checked here
            hr.validate_role_match(p, manifest)

    def test_inspector_role_with_require_fn_passes(self):
        manifest = {"signal": "AGENT_TYPE", "role": "per-call-inspector"}
        content = "require_inspector_agent_type\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            p = _write_sh(tmpdir, "ok.sh", content)
            hr.validate_role_match(p, manifest)


# ── TestDumpsCompact ─────────────────────────────────────────────────────────

class TestDumpsCompact(unittest.TestCase):

    def test_string_array_collapsed_to_single_line(self):
        """Short string-only array collapsed onto one line."""
        obj = {"tools": ["Bash", "Read", "Write"]}
        result = hr.dumps_compact(obj)
        parsed = json.loads(result)
        self.assertEqual(parsed, obj)
        # Collapsed form: no newlines inside the array
        self.assertIn('"tools": ["Bash", "Read", "Write"]', result)

    def test_mixed_content_not_collapsed(self):
        """Array containing non-string values is NOT collapsed."""
        obj = {"items": [{"a": 1}, {"b": 2}]}
        result = hr.dumps_compact(obj)
        parsed = json.loads(result)
        self.assertEqual(parsed, obj)
        # Nested objects stay multi-line
        self.assertIn("\n", result)

    def test_oversize_string_array_not_collapsed(self):
        """String array that exceeds print_width stays multi-line."""
        long_strings = ["very-long-string-number-" + str(i) for i in range(10)]
        obj = {"tools": long_strings}
        result = hr.dumps_compact(obj, print_width=40)
        parsed = json.loads(result)
        self.assertEqual(parsed, obj)
        # The array should be multi-line (won't fit in 40 chars)
        lines = result.split("\n")
        array_lines = [l for l in lines if "very-long-string" in l]
        self.assertGreater(len(array_lines), 1)

    def test_output_is_valid_json(self):
        """dumps_compact always emits valid JSON."""
        obj = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": ["cmd1", "cmd2"]}]}}
        result = hr.dumps_compact(obj)
        parsed = json.loads(result)
        self.assertEqual(parsed, obj)


# ── TestGroupByEvent ─────────────────────────────────────────────────────────

class TestGroupByEvent(unittest.TestCase):

    def test_alpha_sort_within_event(self):
        """Hooks sorted alphabetically by filename within each event."""
        hooks = [
            {"filename": "z-hook.sh", "event": "PreToolUse"},
            {"filename": "a-hook.sh", "event": "PreToolUse"},
            {"filename": "m-hook.sh", "event": "PreToolUse"},
        ]
        result = hr.group_by_event(hooks)
        filenames = [h["filename"] for h in result["PreToolUse"]]
        self.assertEqual(filenames, ["a-hook.sh", "m-hook.sh", "z-hook.sh"])

    def test_multiple_events_grouped_separately(self):
        hooks = [
            {"filename": "b.sh", "event": "Stop"},
            {"filename": "a.sh", "event": "PreToolUse"},
        ]
        result = hr.group_by_event(hooks)
        self.assertIn("Stop", result)
        self.assertIn("PreToolUse", result)
        self.assertEqual(result["Stop"][0]["filename"], "b.sh")
        self.assertEqual(result["PreToolUse"][0]["filename"], "a.sh")

    def test_empty_list_returns_empty_dict(self):
        self.assertEqual(hr.group_by_event([]), {})


# ── TestBuildHookEntry ───────────────────────────────────────────────────────

class TestBuildHookEntry(unittest.TestCase):

    def test_returns_type_command(self):
        manifest = {"filename": "my-hook.sh"}
        result = hr.build_hook_entry(manifest)
        self.assertEqual(result["type"], "command")

    def test_command_contains_hooks_dir_path(self):
        manifest = {"filename": "my-hook.sh"}
        result = hr.build_hook_entry(manifest)
        self.assertIn("$HOME/.claude/hooks/my-hook.sh", result["command"])

    def test_result_is_dict_with_two_keys(self):
        manifest = {"filename": "test.sh"}
        result = hr.build_hook_entry(manifest)
        self.assertIsInstance(result, dict)
        self.assertIn("type", result)
        self.assertIn("command", result)

    def test_timeout_emitted_when_present(self):
        """build_hook_entry includes timeout key when manifest carries it."""
        manifest = {"filename": "stop-resume.sh", "timeout": 360}
        result = hr.build_hook_entry(manifest)
        self.assertEqual(result["timeout"], 360)

    def test_timeout_absent_when_not_in_manifest(self):
        """build_hook_entry must NOT emit timeout for hooks without it (regression guard)."""
        manifest = {"filename": "other-hook.sh"}
        result = hr.build_hook_entry(manifest)
        self.assertNotIn("timeout", result)


# ── TestRenderHeader ─────────────────────────────────────────────────────────

class TestRenderHeader(unittest.TestCase):

    def _base_entry(self, **overrides):
        entry = {
            "id": "my-hook",
            "event": "PreToolUse",
            "tool_guard": "Bash",
            "surface": "user_global",
            "signal": "none",
            "role": "*",
            "harnesses": "all",
        }
        entry.update(overrides)
        return entry

    def test_minimal_entry_renders_all_fields(self):
        h = hr.render_header(self._base_entry())
        self.assertIn("# HOOK-MANIFEST:", h)
        self.assertIn("# event: PreToolUse", h)
        self.assertIn("# matcher: Bash", h)
        self.assertIn("# surface: user_global", h)
        self.assertIn("# signal: none", h)
        self.assertIn("# role: *", h)
        self.assertIn("# harnesses: all", h)
        self.assertIn("# GENERATED FROM shared/enforcement/registry.yaml", h)

    def test_tool_guard_maps_to_matcher(self):
        """Registry tool_guard → header matcher."""
        h = hr.render_header(self._base_entry(tool_guard="Write|Edit"))
        self.assertIn("# matcher: Write|Edit", h)
        self.assertNotIn("tool_guard", h)

    def test_registry_claude_maps_to_claude_code(self):
        """Registry harnesses: claude → header harnesses: claude_code."""
        h = hr.render_header(self._base_entry(harnesses="claude"))
        self.assertIn("# harnesses: claude_code", h)
        self.assertNotIn("# harnesses: claude\n", h)

    def test_harnesses_all_passthrough(self):
        h = hr.render_header(self._base_entry(harnesses="all"))
        self.assertIn("# harnesses: all", h)

    def test_harnesses_pi_passthrough(self):
        h = hr.render_header(self._base_entry(harnesses="pi"))
        self.assertIn("# harnesses: pi", h)

    def test_single_line_rationale(self):
        h = hr.render_header(self._base_entry(rationale="short reason"))
        self.assertIn("# rationale: short reason", h)

    def test_multi_line_rationale_first_line(self):
        h = hr.render_header(self._base_entry(rationale="first line\ncontinuation"))
        self.assertIn("# rationale: first line", h)

    def test_multi_line_rationale_continuation_indented(self):
        h = hr.render_header(self._base_entry(rationale="first line\ncontinuation"))
        self.assertIn("#   continuation", h)

    def test_no_rationale_no_rationale_line(self):
        h = hr.render_header(self._base_entry())
        self.assertNotIn("rationale", h)

    def test_provenance_comment_present(self):
        h = hr.render_header(self._base_entry())
        self.assertIn("# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT", h)

    def test_hook_manifest_is_first_line(self):
        h = hr.render_header(self._base_entry())
        self.assertTrue(h.startswith("# HOOK-MANIFEST:"))

    def test_no_trailing_blank_comment(self):
        """render_header must NOT include trailing '#' — inject_header preserves it from body."""
        h = hr.render_header(self._base_entry())
        # Last line must not be a bare "#"
        last_line = h.splitlines()[-1].strip()
        self.assertNotEqual(last_line, "#")

    def test_timeout_line_emitted_when_set(self):
        """render_header emits # timeout: N when entry carries a timeout."""
        h = hr.render_header(self._base_entry(timeout=360))
        self.assertIn("# timeout: 360", h)

    def test_timeout_line_before_generated_comment(self):
        """# timeout: line appears before the GENERATED FROM provenance comment."""
        h = hr.render_header(self._base_entry(timeout=360))
        timeout_pos = h.index("# timeout: 360")
        generated_pos = h.index("# GENERATED FROM")
        self.assertLess(timeout_pos, generated_pos)

    def test_no_timeout_line_when_absent(self):
        """render_header must NOT emit a timeout line when entry has no timeout."""
        h = hr.render_header(self._base_entry())
        self.assertNotIn("timeout", h)

    def test_glob_role_preserved(self):
        h = hr.render_header(self._base_entry(role="developer-*"))
        self.assertIn("# role: developer-*", h)

    def test_pipe_role_preserved(self):
        h = hr.render_header(self._base_entry(role="reviewer-phoenix|reviewer-static"))
        self.assertIn("# role: reviewer-phoenix|reviewer-static", h)

    def test_per_call_inspector_surface(self):
        h = hr.render_header(self._base_entry(surface="per_call_inspector"))
        self.assertIn("# surface: per_call_inspector", h)

    def test_agent_type_signal(self):
        h = hr.render_header(self._base_entry(signal="AGENT_TYPE"))
        self.assertIn("# signal: AGENT_TYPE", h)

    def test_claude_role_family_signal(self):
        h = hr.render_header(self._base_entry(signal="CLAUDE_ROLE_FAMILY"))
        self.assertIn("# signal: CLAUDE_ROLE_FAMILY", h)


# ── TestInjectHeader ──────────────────────────────────────────────────────────

class TestInjectHeader(unittest.TestCase):

    _HOOK_TEMPLATE = """\
#!/bin/bash
# my-hook.sh — PreToolUse Bash hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: *
# harnesses: all
#
# Body comment line 1.
# Body comment line 2.

set -u
echo "hook body"
exit 0
"""

    def _entry(self, **overrides):
        e = {
            "id": "my-hook",
            "event": "PreToolUse",
            "tool_guard": "Bash",
            "surface": "user_global",
            "signal": "none",
            "role": "*",
            "harnesses": "all",
        }
        e.update(overrides)
        return e

    def test_header_span_replaced(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "my-hook.sh"
            p.write_text(self._HOOK_TEMPLATE)
            entry = self._entry(signal="AGENT_TYPE")
            header = hr.render_header(entry)
            hr.inject_header(p, header)
            result = p.read_text()
        self.assertIn("# signal: AGENT_TYPE", result)
        self.assertNotIn("# signal: none\n", result)

    def test_body_byte_identical_after_inject(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "my-hook.sh"
            p.write_text(self._HOOK_TEMPLATE)
            original_body_start = self._HOOK_TEMPLATE.index("# Body comment line 1")
            original_body = self._HOOK_TEMPLATE[original_body_start:]

            entry = self._entry(signal="AGENT_TYPE")
            header = hr.render_header(entry)
            hr.inject_header(p, header)
            result = p.read_text()

            # Body starts after the terminator "#\n"
            # Find the body in the result
            self.assertIn("# Body comment line 1.", result)
            self.assertIn("echo \"hook body\"", result)
            # Extract body from result (after the blank "#" terminator)
            result_body_start = result.index("# Body comment line 1")
            result_body = result[result_body_start:]
            self.assertEqual(result_body, original_body)

    def test_idempotent_rerun_returns_false(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "my-hook.sh"
            p.write_text(self._HOOK_TEMPLATE)
            # First inject with identical content should be no-op
            entry = self._entry()  # identical to existing header
            header = hr.render_header(entry)
            # inject once to get it to the state with GENERATED FROM line
            hr.inject_header(p, header)
            # Second inject — must be idempotent (no change)
            updated = hr.inject_header(p, header)
        self.assertFalse(updated)

    def test_inject_returns_true_when_updated(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "my-hook.sh"
            p.write_text(self._HOOK_TEMPLATE)
            entry = self._entry(signal="AGENT_TYPE")  # different from existing "none"
            header = hr.render_header(entry)
            updated = hr.inject_header(p, header)
        self.assertTrue(updated)

    def test_no_manifest_line_exits_1(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "no-manifest.sh"
            p.write_text("#!/bin/bash\n# no manifest here\necho hello\n")
            entry = self._entry()
            header = hr.render_header(entry)
            with self.assertRaises(SystemExit) as ctx:
                with unittest.mock.patch("sys.stderr", new_callable=io.StringIO):
                    with unittest.mock.patch("sys.stdout", new_callable=io.StringIO):
                        hr.inject_header(p, header)
        self.assertEqual(ctx.exception.code, 1)


# ── TestRegistrationKindDiscrimination ───────────────────────────────────────

class TestRegistrationKindDiscrimination(unittest.TestCase):

    def test_emit_headers_skips_denial_entries(self):
        """emit_headers only processes kind:registration entries, not denial entries."""
        with tempfile.TemporaryDirectory() as td:
            # Create a registry with one denial and one registration entry
            registry_content = """
- id: denial-hook
  generated: false
  event: PreToolUse
  tool_guard: Bash
  match: "foo"
  message: "deny foo"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all

- kind: registration
  id: reg-hook
  event: PreToolUse
  tool_guard: Bash
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
"""
            registry_path = Path(td) / "registry.yaml"
            registry_path.write_text(registry_content)

            # Create only reg-hook.sh (denial-hook.sh absent — should not be touched)
            reg_sh = Path(td) / "reg-hook.sh"
            reg_sh.write_text(
                "#!/bin/bash\n# HOOK-MANIFEST:\n# event: PreToolUse\n# matcher: Bash\n"
                "# surface: user_global\n# signal: none\n# role: *\n# harnesses: all\n#\necho body\n"
            )

            # emit_headers should succeed and process reg-hook only
            with unittest.mock.patch("sys.stdout", new_callable=io.StringIO):
                hr.emit_headers(registry_path, Path(td), check_only=False)
            # denial-hook.sh was NOT created
            self.assertFalse((Path(td) / "denial-hook.sh").exists())
            # reg-hook.sh still exists
            self.assertTrue(reg_sh.exists())

    def test_check_headers_passes_when_all_match(self):
        """emit_headers check_only=True passes when headers match."""
        with tempfile.TemporaryDirectory() as td:
            registry_content = """
- kind: registration
  id: clean-hook
  event: Stop
  tool_guard: "*"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
"""
            registry_path = Path(td) / "registry.yaml"
            registry_path.write_text(registry_content)

            # Pre-create hook with matching header
            clean_sh = Path(td) / "clean-hook.sh"
            entry = {
                "id": "clean-hook",
                "event": "Stop",
                "tool_guard": "*",
                "surface": "user_global",
                "signal": "none",
                "role": "*",
                "harnesses": "all",
            }
            header = hr.render_header(entry)
            clean_sh.write_text(
                "#!/bin/bash\n"
                + header
                + "\n#\necho body\n"
            )

            # Should not raise
            with unittest.mock.patch("sys.stdout", new_callable=io.StringIO):
                hr.emit_headers(registry_path, Path(td), check_only=True)

    def test_check_headers_fails_on_drift(self):
        """emit_headers check_only=True exits 1 when header drifts from registry."""
        with tempfile.TemporaryDirectory() as td:
            registry_content = """
- kind: registration
  id: drift-hook
  event: Stop
  tool_guard: "*"
  surface: user_global
  signal: AGENT_TYPE
  role: "*"
  harnesses: all
"""
            registry_path = Path(td) / "registry.yaml"
            registry_path.write_text(registry_content)

            # Pre-create hook with DIFFERENT signal
            drift_sh = Path(td) / "drift-hook.sh"
            drift_sh.write_text(
                "#!/bin/bash\n# HOOK-MANIFEST:\n# event: Stop\n# matcher: *\n"
                "# surface: user_global\n# signal: none\n# role: *\n# harnesses: all\n#\necho body\n"
            )

            with self.assertRaises(SystemExit) as ctx:
                with unittest.mock.patch("sys.stderr", new_callable=io.StringIO):
                    with unittest.mock.patch("sys.stdout", new_callable=io.StringIO):
                        hr.emit_headers(registry_path, Path(td), check_only=True)
        self.assertEqual(ctx.exception.code, 1)


# ── TestInspectorSettingsFragment ────────────────────────────────────────────

_INSPECTOR_BASH_MANIFEST = """\
#!/usr/bin/env bash
# HOOK-MANIFEST:
#   event: PreToolUse
#   matcher: Bash
#   surface: per_call_inspector
#   signal: AGENT_TYPE
#   role: inspector|inspector-phoenix
#   harnesses: claude_code
require_inspector_agent_type
"""

_INSPECTOR_READ_MANIFEST = """\
#!/usr/bin/env bash
# HOOK-MANIFEST:
#   event: PreToolUse
#   matcher: Read
#   surface: per_call_inspector
#   signal: AGENT_TYPE
#   role: inspector|inspector-phoenix
#   harnesses: claude_code
require_inspector_agent_type
"""

_INSPECTOR_WRITE_MANIFEST = """\
#!/usr/bin/env bash
# HOOK-MANIFEST:
#   event: PreToolUse
#   matcher: Write|Edit|MultiEdit|NotebookEdit
#   surface: per_call_inspector
#   signal: AGENT_TYPE
#   role: inspector|inspector-phoenix
#   harnesses: claude_code
require_inspector_agent_type
"""

_USER_GLOBAL_MANIFEST = """\
#!/usr/bin/env bash
# HOOK-MANIFEST:
#   event: PreToolUse
#   matcher: Bash
#   surface: user_global
#   signal: AGENT_TYPE
#   role: developer-phoenix-backend
[ "$AGENT_TYPE" = "developer-phoenix-backend" ] || exit 0
"""


def _write_inspector_fixtures(tmpdir: str):
    """Write 3 inspector hooks + 1 user_global hook into tmpdir."""
    _write_sh(tmpdir, "claude-inspector-bash-guard.sh", _INSPECTOR_BASH_MANIFEST)
    _write_sh(tmpdir, "claude-inspector-read-guard.sh", _INSPECTOR_READ_MANIFEST)
    _write_sh(tmpdir, "claude-inspector-write-guard.sh", _INSPECTOR_WRITE_MANIFEST)
    _write_sh(tmpdir, "some-developer-hook.sh", _USER_GLOBAL_MANIFEST)


class TestInspectorSettingsFragment(unittest.TestCase):

    def test_inspector_fragment_contains_three_inspector_hooks(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            _write_inspector_fixtures(tmpdir)
            all_hooks = hr.collect_hooks(Path(tmpdir))
            per_call_hooks = [
                h for h in all_hooks if h["surface"] in ("per_call_inspector", "both")
            ]
            out_path = Path(tmpdir) / "generated" / "claude-code" / "inspector-settings.json"
            # Parent dir does not exist yet — exercises mkdir logic
            self.assertFalse(out_path.parent.exists())
            hr.write_inspector_settings(per_call_hooks, out_path)
            data = json.loads(out_path.read_text())

        # Shape: only "hooks" at top level
        self.assertEqual(set(data.keys()), {"hooks"})

        # Exactly 3 PreToolUse entries
        pre_tool_use = data["hooks"]["PreToolUse"]
        self.assertEqual(len(pre_tool_use), 3)

        # Command basenames match the 3 inspector hook filenames
        basenames = set()
        for entry in pre_tool_use:
            for hook_cmd in entry["hooks"]:
                basenames.add(hook_cmd["command"].split("/")[-1])
        self.assertEqual(
            basenames,
            {
                "claude-inspector-bash-guard.sh",
                "claude-inspector-read-guard.sh",
                "claude-inspector-write-guard.sh",
            },
        )

        # Matchers per hook are correct
        matcher_map = {
            entry["hooks"][0]["command"].split("/")[-1]: entry["matcher"]
            for entry in pre_tool_use
        }
        self.assertEqual(matcher_map["claude-inspector-bash-guard.sh"], "Bash")
        self.assertEqual(matcher_map["claude-inspector-read-guard.sh"], "Read")
        self.assertEqual(
            matcher_map["claude-inspector-write-guard.sh"],
            "Write|Edit|MultiEdit|NotebookEdit",
        )

    def test_main_settings_has_zero_inspector_hooks(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            _write_inspector_fixtures(tmpdir)
            all_hooks = hr.collect_hooks(Path(tmpdir))
            user_global_hooks = [
                h for h in all_hooks if h["surface"] in ("user_global", "both")
            ]
            settings_path = Path(tmpdir) / "claude-code-settings.json"
            hr.regenerate_settings({}, user_global_hooks, settings_path)
            data = json.loads(settings_path.read_text())
            raw = settings_path.read_text()

        # No inspector hook names anywhere in the serialized settings
        self.assertNotIn("claude-inspector", raw)

        # No PreToolUse entry command references inspector
        for entry in data.get("hooks", {}).get("PreToolUse", []):
            for hook_cmd in entry.get("hooks", []):
                self.assertNotIn("inspector", hook_cmd.get("command", ""))


if __name__ == "__main__":
    unittest.main()
