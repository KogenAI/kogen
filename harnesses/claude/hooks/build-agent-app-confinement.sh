#!/bin/bash
# build-agent-app-confinement.sh — PreToolUse Write|Edit|MultiEdit hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Write|Edit|MultiEdit
# surface: user_global
# signal: none
# role: *
# harnesses: all
# rationale: Denies Write/Edit/MultiEdit when CODEGEN_BUILD_CWD is set and the target file resolves outside that dir, confining managed build subagents to the app sandbox. Fills the orchestrator-no-source-edit.sh subagent pass-through gap (AGENT_ID set -> exit 0). Env-keyed (CODEGEN_BUILD_CWD), role-agnostic; composes with orchestrator-no-source-edit and build-worker-cwd-guard.
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Confines managed build agents (CODEGEN_BUILD_CWD set) to their app sandbox.
# Denies Write/Edit/MultiEdit to any path that resolves outside CODEGEN_BUILD_CWD.
#
# Escape hatches:
#   - CODEGEN_BUILD_CWD unset → inert (not a managed build)
#   - /tmp/ and /private/tmp/ → always allowed (scratch)
#   - Target inside or equal to CODEGEN_BUILD_CWD (after canonicalization) → allow
#
# Sibling-prefix safety: appends trailing slash to CODEGEN_BUILD_CWD before
# prefix-compare so /apps/app cannot match /apps/app2.
# macOS symlink safety: hooks_realpath resolves /var → /private/var.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

build_cwd="${CODEGEN_BUILD_CWD:-}"

debug_log build-agent-app-confinement "tool=$TOOL_NAME build_cwd=$build_cwd file=$FILE_PATH"

# Inert outside a managed build.
if [ -z "$build_cwd" ]; then
    exit 0
fi

# Only Write/Edit/MultiEdit are in scope (matcher gates, defensive here).
case "$TOOL_NAME" in
Write | Edit | MultiEdit) ;;
*) exit 0 ;;
esac

# fail-closed: matcher is Write|Edit|MultiEdit (file-bearing); empty path is
# an anomaly, not a legitimate skip (interaction-composition proof verified —
# every reachable caller here is a file-bearing tool call).
if [ -z "$FILE_PATH" ]; then
    deny "BLOCKED by build-agent-app-confinement: empty/unresolvable file path on a Write|Edit|MultiEdit call inside a managed build (CODEGEN_BUILD_CWD set). A file-bearing tool with no path is anomalous; failing closed. Provide an explicit path under the sandbox."
    exit 0
fi

# Scratch escape hatch — absolute /tmp paths allowed even outside the sandbox.
case "$FILE_PATH" in
/tmp/* | /private/tmp/*)
    exit 0
    ;;
esac

# Canonicalize both sides. hooks_realpath resolves symlinks and prepends $PWD
# for relative/non-existent paths (during a build, $PWD == CODEGEN_BUILD_CWD).
canon_cwd=$(hooks_realpath "$build_cwd")
canon_file=$(hooks_realpath "$FILE_PATH")

# Append trailing slash to prevent sibling-prefix false-allow
# (/apps/app must not match /apps/app2).
case "$canon_cwd" in
*/) cwd_prefix="$canon_cwd" ;;
*) cwd_prefix="${canon_cwd}/" ;;
esac

# Inside the sandbox (or equal to it) → allow.
if [ "$canon_file" = "$canon_cwd" ]; then
    exit 0
fi
case "$canon_file" in
"${cwd_prefix}"*)
    exit 0
    ;;
esac

deny "BLOCKED by build-agent-app-confinement: managed build agents may only write inside the app sandbox ($canon_cwd). Got: $canon_file (outside CODEGEN_BUILD_CWD). Write to a path under the sandbox, or use /tmp for scratch."
exit 0
