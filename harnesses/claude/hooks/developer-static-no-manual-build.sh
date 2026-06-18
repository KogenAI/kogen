#!/bin/bash
# developer-static-no-manual-build.sh — PreToolUse hook: developer-static may not run static build/verify commands manually (gate owns verification).
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: developer-static
# harnesses: all
#
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
# Edit registry.yaml and run `make install` to regenerate.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log developer-static-no-manual-build "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only apply to role(s): developer-static
case "$AGENT_TYPE" in
developer-static) ;;
*) exit 0 ;;
esac

# Deny: pattern match.
if printf '%s' "$COMMAND" | grep -qE '(render|wiring)-check\.js|npm[[:space:]]+(run[[:space:]]+)?(build|serve)|vite[[:space:]]+build|playwright'; then
    deny "BLOCKED by developer-static-no-manual-build: do not run build/render/wiring-check/serve/playwright manually. The static-site-build-check gate runs verification automatically on SubagentStop. Manual runs cause thrash."
    exit 0
fi

exit 0
