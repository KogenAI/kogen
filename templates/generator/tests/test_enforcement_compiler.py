"""Unit tests for enforcement_compiler.py — covers _render_bash and _render_ts
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


class TestRenderTsFilePathDeny(unittest.TestCase):
    """_render_ts — FILE_PATH + mode=deny branch."""

    def setUp(self):
        self.ts = ec._render_ts(_ENTRY_FILEPATH_DENY)

    def test_has_generated_header(self):
        self.assertIn("GENERATED FROM shared/enforcement/registry.yaml", self.ts)
        self.assertIn("DO NOT EDIT", self.ts)

    def test_imports_repo_relative(self):
        self.assertIn("repoRelative", self.ts)

    def test_multi_tool_ts_check(self):
        # Read, Grep, Glob all in the toolName check
        self.assertIn('event.toolName === "read"', self.ts)
        self.assertIn('event.toolName === "grep"', self.ts)
        self.assertIn('event.toolName === "glob"', self.ts)

    def test_reads_both_file_path_and_path(self):
        # Must extract from file_path OR path (for Grep/Glob)
        self.assertIn("file_path", self.ts)
        self.assertIn("input.path", self.ts)

    def test_positive_match_returns_deny(self):
        # match → return deny(...)
        self.assertIn("return deny(", self.ts)

    def test_no_unconditional_deny(self):
        # No deny outside the if-match block (allow path just returns without deny)
        # Count occurrences of "return deny" — must be exactly 1
        self.assertEqual(self.ts.count("return deny("), 1)

    def test_repo_relative_canonicalize(self):
        self.assertIn("repoRelative(filePath)", self.ts)

    def test_agent_type_guard_present(self):
        self.assertIn('agentType === "developer-static"', self.ts)

    def test_match_ts_pattern_escapes_slashes(self):
        # /→\/ in TS regex literals
        self.assertIn(r"(^|\/)public\/|(^|\/)dist\/", self.ts)

    def test_message_in_deny_call(self):
        self.assertIn("BLOCKED by developer-static-no-build-output-probe", self.ts)


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


class TestRenderTsCommandDeny(unittest.TestCase):
    """_render_ts — COMMAND + mode=deny (default) branch — AGENT_TYPE guard present."""

    def setUp(self):
        self.ts = ec._render_ts(_ENTRY_COMMAND_DENY)

    def test_denies_on_match(self):
        self.assertIn("return deny(", self.ts)

    def test_checks_command_not_file_path(self):
        self.assertIn("command", self.ts)

    def test_agent_type_guard_present(self):
        # role: developer-static → agentType guard emitted
        self.assertIn('agentType === "developer-static"', self.ts)

    def test_agent_type_guard_blocks_other_roles(self):
        # Guard must use negation so non-developer-static roles return early
        self.assertIn("if (!(", self.ts)

    def test_pattern_in_output(self):
        # Pattern appears as a JS regex
        self.assertIn("render|wiring", self.ts)


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
    """_render_bash / _render_ts — ignore_quoted opt-in on the COMMAND+deny
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

    def test_ts_without_ignore_quoted_uses_bare_command(self):
        ts = ec._render_ts(_ENTRY_COMMAND_DENY)
        self.assertIn(".test(command)", ts)
        self.assertNotIn("stripQuoted", ts)
        self.assertNotIn(", stripQuoted", ts)

    def test_ts_with_ignore_quoted_uses_strip_quoted(self):
        entry = dict(_ENTRY_COMMAND_DENY, ignore_quoted=True)
        ts = ec._render_ts(entry)
        self.assertIn(".test(stripQuoted(command))", ts)
        self.assertIn("stripQuoted", ts)
        # Import line must pull in the new helper alongside the existing ones.
        self.assertIn(
            "import { deny, debugLog, isCodegenLogWrite, stripQuoted }", ts
        )


class TestResolveIndirectionOptIn(unittest.TestCase):
    """_render_bash / _render_ts — resolve_indirection opt-in on the
    COMMAND+deny SINGLE branch. Default-off MUST render byte-identical
    subject literals to the pre-existing template (byte-parity regression
    guard, mirrors TestRenderIgnoreQuoted); opt-in wraps the match subject
    in expand_command_indirection/expandCommandIndirection so a destructive
    verb hidden in a bash/sh/zsh/source-referenced script body is scanned
    too (see the "a guard on a verb is a guard on spelling" pitch).
    """

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

    def test_ts_without_resolve_indirection_uses_bare_command(self):
        ts = ec._render_ts(_ENTRY_COMMAND_DENY)
        self.assertIn(".test(command)", ts)
        self.assertNotIn("expandCommandIndirection", ts)

    def test_ts_with_resolve_indirection_wraps_subject(self):
        entry = dict(_ENTRY_COMMAND_DENY, resolve_indirection=True)
        ts = ec._render_ts(entry)
        self.assertIn(".test(expandCommandIndirection(command))", ts)
        # Import line must pull in the new helper alongside the existing ones.
        self.assertIn(
            "import { deny, debugLog, isCodegenLogWrite, expandCommandIndirection }",
            ts,
        )

    def test_ts_with_both_ignore_quoted_and_resolve_indirection_composes(self):
        entry = dict(_ENTRY_COMMAND_DENY, ignore_quoted=True, resolve_indirection=True)
        ts = ec._render_ts(entry)
        self.assertIn(
            ".test(expandCommandIndirection(stripQuoted(command)))", ts
        )
        self.assertIn(
            "import { deny, debugLog, isCodegenLogWrite, stripQuoted, expandCommandIndirection }",
            ts,
        )


class TestValidateHarnesses(unittest.TestCase):
    """_validate_harnesses — token-set guard (seam b)."""

    def test_all_passes(self):
        ec._validate_harnesses("some-id", "all")  # no raise

    def test_claude_passes(self):
        ec._validate_harnesses("some-id", "claude")

    def test_pi_passes(self):
        ec._validate_harnesses("some-id", "pi")

    def test_bogus_token_exits(self):
        with self.assertRaises(SystemExit) as cm:
            ec._validate_harnesses("my-id", "claude_code")
        msg = str(cm.exception)
        self.assertIn("my-id", msg)
        self.assertIn("claude_code", msg)
        self.assertIn("not in (all, claude, pi)", msg)


if __name__ == "__main__":
    unittest.main()
