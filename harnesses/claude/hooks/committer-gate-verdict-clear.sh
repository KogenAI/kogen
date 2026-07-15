#!/bin/bash
# committer-gate-verdict-clear.sh — PreToolUse Bash hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
# rationale: Denies a git commit from the committer agent unless codegen/gate-pending/gate-result.json exists and its .verdict field is "clear" — enforces the mandatory verdict read (shared/rules/roles/committer.md) rather than leaving it as an unenforced instruction.
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# The committer's own rule (shared/rules/roles/committer.md) says: read the
# .verdict field of codegen/gate-pending/gate-result.json; absent or non-clear
# → do not commit. That rule was never enforced — nothing stopped a committer
# from skipping the read and committing anyway. This hook makes it structural.
#
# Allow conditions:
#   - AGENT_TYPE != "committer" (defensive; registry already scopes this hook)
#   - Tool call is not Bash
#   - A codegen-log write (narrates gated phrases in its heredoc body; never
#     the gated action itself)
#   - Command does not contain `git commit`
#   - gate-result.json exists and its .verdict field == "clear"
#
# Deny conditions:
#   - gate-result.json is absent
#   - gate-result.json exists but .verdict != "clear" (failed, inconclusive,
#     malformed JSON, or missing verdict field)
#
# Verdict-only: no freshness/base_sha check here (that belongs to a sibling
# concern, not duplicated in this hook).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/lib/gate-result.sh"
parse_input

debug_log committer-gate-verdict-clear "tool=$TOOL_NAME agent=$AGENT_TYPE"

if [ "$AGENT_TYPE" != "committer" ]; then
    exit 0
fi

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match.
if is_codegen_log_write; then
    exit 0
fi

if ! printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+commit([[:space:];&|]|$)'; then
    exit 0
fi

project_dir="${CLAUDE_PROJECT_DIR:-${CWD:-$PWD}}"

result_file="$project_dir/codegen/gate-pending/gate-result.json"
if [ ! -f "$result_file" ]; then
    deny "BLOCKED by committer-gate-verdict-clear: codegen/gate-pending/gate-result.json is missing. The gate verdict cannot be confirmed. Do not commit until a gate run has produced a clear verdict."
    exit 0
fi

verdict="$(gate_result_verdict "$project_dir")"

if [ "$verdict" != "clear" ]; then
    deny "BLOCKED by committer-gate-verdict-clear: gate-result.json verdict is '${verdict:-absent}' (need 'clear'). Do not commit — the build has not reached a clear gate verdict."
    exit 0
fi

debug_log committer-gate-verdict-clear "allow: verdict=clear"
exit 0
