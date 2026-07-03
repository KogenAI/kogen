#!/bin/bash
# context-file-size-gate.sh — PreToolUse hook: deny `git commit` when any staged
# context/*.md blob exceeds the 40,960-byte (40k) cap. This is a commit-time
# BACKSTOP — the primary enforcement is curator-context-size-gate.sh, which
# denies the over-cap Edit/Write in the context-curator's own turn. The
# committer cannot Read or edit context/*.md, so this backstop's deny message
# routes the orchestrator to re-spawn the context-curator, never the committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: none
# role: unset
# harnesses: all
#
# Firing contract: no CLAUDE_ROLE gating (signal: none) — fires for all roles in all repos.
# Subagent inheritance: intentional — committer runs as subagent and this hook MUST
#   block its commits. Do NOT call is_outer_session().
#
# Blocks: git commit (any form) when a staged context/<file>.md (Added or Modified,
#         direct child of context/ only) has a staged-blob byte size > 40960.
# Allows: git commit with no over-cap context/*.md; non-commit Bash; non-Bash tools;
#         commands outside a git repo.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-file-size-gate "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

CAP=40960

if [ "$TOOL_NAME" != "Bash" ]; then exit 0; fi
if ! printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&|])git[[:space:]]+commit\b'; then exit 0; fi
if [ -z "$CWD" ] || ! git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then exit 0; fi
repo_root=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then exit 0; fi

staged=$(git -C "$repo_root" diff --cached --name-status 2>/dev/null |
    grep -E '^[AM][[:space:]]+context/[^/]+\.md$' |
    awk '{print $2}' || true)
if [ -z "$staged" ]; then exit 0; fi

violations=""
while IFS= read -r fpath; do
    [ -z "$fpath" ] && continue
    bytes=$(git -C "$repo_root" show :"$fpath" 2>/dev/null | wc -c | tr -d ' ')
    [ -z "$bytes" ] && continue
    if [ "$bytes" -gt "$CAP" ]; then
        violations="${violations}${violations:+$'\n'}context-file-size-gate (backstop): staged context file ${fpath} is ${bytes} bytes, over the ${CAP}-byte (40k) cap. The committer cannot Read or edit context/*.md — do NOT trim it here. Orchestrator: re-spawn the context-curator to compress or split ${fpath} under 40960 bytes, then re-run the cycle."
    fi
done <<EOF
$staged
EOF

if [ -n "$violations" ]; then deny "$violations"; fi
exit 0
