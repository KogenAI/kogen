#!/bin/bash
# reviewer-bash-allowlist.sh — PreToolUse hook: reviewer may only run codegen-log and safe read-only shell utilities (allowlist).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: reviewer-phoenix|reviewer-static
# harnesses: all
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log reviewer-bash-allowlist "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only apply to role(s): reviewer-phoenix|reviewer-static
case "$AGENT_TYPE" in
reviewer-phoenix | reviewer-static) ;;
*) exit 0 ;;
esac

# Allowlist: allow matching commands; deny everything else.
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]]|/)codegen-log\b|^[[:space:]]*(cd[[:space:]]+\S+[[:space:]]+&&[[:space:]]+)?(git[[:space:]]+(-C[[:space:]]+\S+[[:space:]]+)?(diff|status|log|show)\b|echo\b|wc\b|cat\b|ls\b|true\b|:)'; then
    exit 0
fi

deny "BLOCKED by reviewer-bash-allowlist: only codegen-log and safe read-only shell utilities (git diff/status/log/show, echo, wc, cat, ls, true, :) allowed for reviewer"
exit 0
