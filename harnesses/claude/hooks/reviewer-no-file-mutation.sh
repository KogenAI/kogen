#!/bin/bash
# reviewer-no-file-mutation.sh — PreToolUse hook: reviewer may not write files via sed -i or shell output redirection, including combined fd+stdout redirects (&>, &>>) (ignore_quoted: true — a `>` inside a quoted jq/awk filter string is a mention, not a redirection; a redirect targeting exactly /dev/null is a discard, never a file write, so it is excluded from the redirect branch).
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

debug_log reviewer-no-file-mutation "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# Only apply to role(s): reviewer-phoenix|reviewer-static
case "$AGENT_TYPE" in
reviewer-phoenix | reviewer-static) ;;
*) exit 0 ;;
esac

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Deny: pattern match.
if printf '%s' "$(strip_quoted "$COMMAND")" | grep -qE '\bsed\b[^|;&]*(-i\b|--in-place\b)|>>?[[:space:]]*([^/&[:space:]]|/[^d]|/d[^e]|/de[^v]|/dev[^/]|/dev/[^n]|/dev/n[^u]|/dev/nu[^l]|/dev/nul[^l]|/dev/null[^&[:space:]])'; then
    deny "BLOCKED by reviewer-no-file-mutation: reviewer is read-only — do not write files via \`sed -i\`/\`sed --in-place\` or shell output redirection (>, >>). Report the finding instead; the developer role fixes it."
    exit 0
fi

exit 0
