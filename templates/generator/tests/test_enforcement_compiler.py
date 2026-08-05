"""Unit tests for enforcement_compiler.py — covers _render_bash
for the FILE_PATH + deny mode branch (match→deny, no-match→allow).
"""

import sys
import unittest
from pathlib import Path

# Ensure the generator dir is importable regardless of cwd.
_GENERATOR_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(_GENERATOR_DIR))

import enforcement_compiler as ec  # noqa: E402

# ---------------------------------------------------------------------------
# Shared fixture — minimal FILE_PATH deny registry entry
# ---------------------------------------------------------------------------

_ENTRY_FILEPATH_DENY = {
    "id": "developer-static-no-build-output-probe",
    "description": "developer-static may not probe build-output dirs (public/, dist/) via Read/Grep/Glob",
    "event": "PreToolUse",
    "source": "FILE_PATH",
    "mode": "deny",
    "canonicalize": "repo_relative",
    "tool_guard": "Read|Grep|Glob",
    "match": "(^|/)public/|(^|/)dist/",
    "message": "BLOCKED by developer-static-no-build-output-probe: do not read/grep/glob generated build output (public/, dist/). Inspect SOURCE files; the gate verifies build output automatically.",
    "surface": "user_global",
    "signal": "AGENT_TYPE",
    "role": "developer-static",
    "harnesses": "all",
    "generated": True,
}

# Minimal COMMAND deny entry — exercises the default COMMAND+deny path (unchanged).
_ENTRY_COMMAND_DENY = {
    "id": "developer-static-no-manual-build",
    "description": "developer-static may not run static build/verify commands manually (gate owns verification)",
    "event": "PreToolUse",
    "source": "COMMAND",
    "tool_guard": "Bash",
    "match": "(render|wiring)-check\\.js|npm\\s+(run\\s+)?(build|serve)|vite\\s+build|playwright",
    "message": "BLOCKED by developer-static-no-manual-build: do not run build/render/wiring-check/serve/playwright manually. The static-site-build-check gate runs verification automatically on SubagentStop. Manual runs cause thrash.",
    "surface": "user_global",
    "signal": "AGENT_TYPE",
    "role": "developer-static",
    "harnesses": "all",
    "generated": True,
}


class TestRenderBashFilePathDeny(unittest.TestCase):
    """_render_bash — FILE_PATH + mode=deny branch."""

    def setUp(self):
        self.bash = ec._render_bash(_ENTRY_FILEPATH_DENY)

    def test_has_generated_header(self):
        self.assertIn("GENERATED FROM shared/enforcement/registry.yaml", self.bash)
        self.assertIn("DO NOT EDIT", self.bash)

    def test_has_hook_manifest(self):
        self.assertIn("# HOOK-MANIFEST:", self.bash)
        self.assertIn("event: PreToolUse", self.bash)
        self.assertIn("matcher: Read|Grep|Glob", self.bash)

    def test_multi_tool_case_arms(self):
        # All three tools appear in case arms
        self.assertIn("Read) ;;", self.bash)
        self.assertIn("Grep) ;;", self.bash)
        self.assertIn("Glob) ;;", self.bash)

    def test_positive_match_denies(self):
        # On match → deny call (NOT exit 0 first)
        # Pattern: if grep -qE ... ; then deny "..." ; exit 0 ; fi ; exit 0
        self.assertIn("deny ", self.bash)
        # The deny is inside the if-match block
        idx_if = self.bash.index("if printf '%s' \"$rel\" | grep -qE")
        idx_deny = self.bash.index("deny ", idx_if)
        # deny comes after the if
        self.assertLess(idx_if, idx_deny)

    def test_no_unconditional_deny(self):
        # After the if-block the script exits 0 (allow), not deny
        # Confirm trailing 'exit 0' after fi
        self.assertIn("fi\n\nexit 0\n", self.bash)

    def test_repo_relative_canonicalize(self):
        self.assertIn('rel=$(repo_relative "$FILE_PATH")', self.bash)

    def test_agent_type_guard_present(self):
        # role: developer-static → case-guard emitted
        self.assertIn('case "$AGENT_TYPE" in', self.bash)
        self.assertIn("developer-static) ;;", self.bash)

    def test_match_bash_pattern(self):
        # (^|/)public/|(^|/)dist/ pattern present (no \s translation needed)
        self.assertIn("(^|/)public/|(^|/)dist/", self.bash)

    def test_message_in_deny_call(self):
        self.assertIn("BLOCKED by developer-static-no-build-output-probe", self.bash)

    def test_file_path_in_deny_call(self):
        # deny call appends $FILE_PATH
        self.assertIn('"$FILE_PATH"', self.bash)


class TestRenderBashCommandDeny(unittest.TestCase):
    """_render_bash — COMMAND + mode=deny (default) branch — ensure no regression."""

    def setUp(self):
        self.bash = ec._render_bash(_ENTRY_COMMAND_DENY)

    def test_denies_on_match(self):
        self.assertIn("deny ", self.bash)

    def test_checks_command_not_file_path(self):
        self.assertIn('"$COMMAND"', self.bash)

    def test_agent_type_guard_present(self):
        # role: developer-static → AGENT_TYPE case-guard emitted
        self.assertIn('case "$AGENT_TYPE" in', self.bash)
        self.assertIn("developer-static) ;;", self.bash)

    def test_pattern_in_output(self):
        # \s → [[:space:]] translation
        self.assertIn("[[:space:]]", self.bash)


class TestFilePathDenyNoCrossContamination(unittest.TestCase):
    """FILE_PATH+deny and FILE_PATH+allowlist are separate branches (no regression)."""

    def test_allowlist_entry_still_renders_allowlist_logic(self):
        allowlist_entry = {
            "id": "committer-write-allowlist",
            "description": "committer may only write to session logs",
            "event": "PreToolUse",
            "source": "FILE_PATH",
            "mode": "allowlist",
            "canonicalize": "repo_relative",
            "tool_guard": "Write|Edit",
            "match": r"codegen/logging/.*\.md$",
            "message": "BLOCKED by committer-write-allowlist",
            "surface": "user_global",
            "signal": "AGENT_TYPE",
            "role": "committer",
            "harnesses": "all",
        }
        bash = ec._render_bash(allowlist_entry)
        # Allowlist: deny is OUTSIDE the if-match block (unconditional deny at end)
        self.assertIn("deny ", bash)
        # In allowlist mode the if-match block exits 0 (allow), then deny at end
        self.assertIn("exit 0\nfi\n\ndeny ", bash)


class TestRenderIgnoreQuoted(unittest.TestCase):
    """_render_bash — ignore_quoted opt-in on the COMMAND+deny
    SINGLE branch. Default-off MUST render byte-identical subject literals
    to the pre-existing template (byte-parity regression guard); opt-in
    routes the match subject through strip_quoted/stripQuoted.
    """

    def test_bash_without_ignore_quoted_uses_bare_command(self):
        bash = ec._render_bash(_ENTRY_COMMAND_DENY)
        self.assertIn('printf \'%s\' "$COMMAND" | grep -qE', bash)
        self.assertNotIn("strip_quoted", bash)

    def test_bash_with_ignore_quoted_uses_strip_quoted(self):
        entry = dict(_ENTRY_COMMAND_DENY, ignore_quoted=True)
        bash = ec._render_bash(entry)
        self.assertIn(
            'printf \'%s\' "$(strip_quoted "$COMMAND")" | grep -qE', bash
        )

    def test_bash_without_resolve_indirection_uses_bare_command(self):
        bash = ec._render_bash(_ENTRY_COMMAND_DENY)
        self.assertIn('printf \'%s\' "$COMMAND" | grep -qE', bash)
        self.assertNotIn("expand_command_indirection", bash)

    def test_bash_with_resolve_indirection_wraps_subject(self):
        entry = dict(_ENTRY_COMMAND_DENY, resolve_indirection=True)
        bash = ec._render_bash(entry)
        self.assertIn(
            'printf \'%s\' "$(expand_command_indirection "$COMMAND")" | grep -qE',
            bash,
        )

    def test_bash_with_both_ignore_quoted_and_resolve_indirection_composes(self):
        entry = dict(_ENTRY_COMMAND_DENY, ignore_quoted=True, resolve_indirection=True)
        bash = ec._render_bash(entry)
        self.assertIn(
            'printf \'%s\' "$(expand_command_indirection "$(strip_quoted "$COMMAND")")" | grep -qE',
            bash,
        )

    def test_all_passes(self):
        ec._validate_harnesses("some-id", "all")  # no raise

    def test_claude_passes(self):
        ec._validate_harnesses("some-id", "claude")

    def test_bogus_token_exits(self):
        with self.assertRaises(SystemExit) as cm:
            ec._validate_harnesses("my-id", "claude_code")
        msg = str(cm.exception)
        self.assertIn("my-id", msg)
        self.assertIn("claude_code", msg)
        self.assertIn("not in (all, claude)", msg)


if __name__ == "__main__":
    unittest.main()
