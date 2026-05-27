"""Unit tests for hook_registrations.py — cover parse_manifest, validate_signal,
validate_role_match, dumps_compact, _hook_fits_stack, group_by_event, build_hook_entry.
"""

import io
import json
import os
import sys
import tempfile
import unittest
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


# ── TestHookFitsStack ────────────────────────────────────────────────────────

class TestHookFitsStack(unittest.TestCase):

    def _hook(self, matcher, role, surface="user_global"):
        return {"matcher": matcher, "role": role, "surface": surface}

    def test_all_generic_matcher_returns_true(self):
        """All matcher tokens are generic → fits every stack."""
        hook = self._hook("Bash", "*")
        self.assertTrue(hr._hook_fits_stack(hook, ["developer-phoenix-backend"]))

    def test_matcher_intersects_agent_set(self):
        """Matcher token in agent set → True."""
        hook = self._hook("developer-phoenix-backend", "*")
        self.assertTrue(hr._hook_fits_stack(hook, ["developer-phoenix-backend", "committer"]))

    def test_role_wildcard_returns_true(self):
        """Role = '*' → True regardless of matcher/agent_set."""
        hook = self._hook("SomeSpecialTool", "*")
        self.assertTrue(hr._hook_fits_stack(hook, ["committer"]))

    def test_role_glob_ends_with_star_returns_true(self):
        """Role ends with -* → True (developer-*, planner-*, etc.)."""
        hook = self._hook("SomeSpecialTool", "developer-*")
        self.assertTrue(hr._hook_fits_stack(hook, ["committer"]))

    def test_role_token_in_agent_set_returns_true(self):
        """Literal role token in agent_set → True."""
        hook = self._hook("SomeSpecialTool", "planner-phoenix")
        self.assertTrue(hr._hook_fits_stack(hook, ["planner-phoenix", "committer"]))

    def test_no_match_returns_false(self):
        """No matcher, role, or wildcard match → False."""
        hook = self._hook("SomeSpecialTool", "planner-phoenix")
        self.assertFalse(hr._hook_fits_stack(hook, ["committer", "reviewer-phoenix"]))


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


if __name__ == "__main__":
    unittest.main()
