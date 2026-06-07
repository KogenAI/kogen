#!/bin/bash
# committer-tool-guard.sh — PreToolUse hook scoped to committer.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Write|Edit
# surface: user_global
# signal: AGENT_TYPE
# role: committer
# harnesses: all
#
# Bash branch: deny build/test/package-manager commands (denylist).
#   Accepted risk: a build tool not in the denylist slips through.
#   True default-deny Bash allowlist requires compiler support tracked in
#   pitch reusable-role-scoped-guards.md — out of scope here.
#   Denylist tools: make mix npm npx node yarn pnpm pytest cargo bundle
#
# Write|Edit branch: allow only canonical session-log paths, deny all else.
#   Allowlist regex (SCHEMA: session-log.md):
#     codegen/logging/[0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)\.md$

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log committer-tool-guard "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate the committer
if [ "$AGENT_TYPE" != "committer" ]; then
    exit 0
fi

case "$TOOL_NAME" in
Bash)
    # Deny known build/test/package-manager tools.
    # Word-boundary anchored to avoid matching e.g. "mixnode" or "npmrc".
    # Accepted gap: denylist only — new/unlisted build tools pass through.
    if printf '%s' "$COMMAND" | grep -qE '(^|[^[:alnum:]_])(make|mix|npm|npx|node|yarn|pnpm|pytest|cargo|bundle)([^[:alnum:]_]|$)'; then
        deny "BLOCKED by committer-tool-guard: build/test tool forbidden for committer. Only git read/write commands allowed. (Denylist gap accepted per pitch reusable-role-scoped-guards.md)"
        exit 0
    fi
    exit 0
    ;;
Write | Edit)
    # Allow only canonical session-log paths; deny source file edits.
    rel=$(repo_relative "$FILE_PATH")
    if printf '%s' "$rel" | grep -qE 'codegen/logging/[0-9]{8}_[0-9]{6}(_[a-z0-9-]+)?_(session|step[0-9]+_[a-z0-9-]+)\.md$'; then
        exit 0
    fi
    deny "BLOCKED by committer-tool-guard: committer may only write to canonical session logs, not: $FILE_PATH"
    exit 0
    ;;
*)
    exit 0
    ;;
esac
