#!/bin/bash
# step-log-section-before-spawn.sh — PreToolUse Agent hook.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Agent
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Blocks subagent spawn when (a) no step log has been written yet or
# (b) the required section header for the spawned agent is absent from the log.
#
# Logic:
#   If TOOL_NAME != "Agent" → exit 0 (not our concern)
#   Resolve launcher role via resolve_role(); bypass for debug/shape/ops.
#   Read subagent_type from tool_input.
#   Map subagent_type → expected header:
#     planner-* → "## Plan"
#     anything else → "## <subagent_type> Section"
#   Locate step log via session_log_from_transcript.
#   If no log found → deny "create step log FIRST before spawning <type>"
#   If log exists but expected header absent → deny naming the missing header
#   Else → allow
#
# Fail-open: if transcript is unreadable, allow (cannot determine state).
# Only blocks when state is KNOWN to be missing.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

# Only guard the Agent tool (subagent spawn).
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

_role=$(resolve_role)
debug_log step-log-section-before-spawn "role=$_role"
if ! is_build_mode; then
    debug_log step-log-section-before-spawn "investigative mode bypass: allowing Agent spawn (role=$_role)"
    exit 0
fi

subagent_type=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)

debug_log step-log-section-before-spawn "subagent_type=$subagent_type"

# Forbidden-type skip guard — defer to operator-subagent-allowlist for types it will deny.
# These 5 cases exactly mirror the allowlist's build-mode forbidden set:
#   Plan, general-purpose, statusline-setup — built-in types denied always
#   "" (empty) — denied defensively by allowlist
#   Explore — denied in build mode (only allowed under debug/shape/ops, already bypassed above)
if [ "$subagent_type" = "Plan" ] || [ "$subagent_type" = "general-purpose" ] ||
    [ "$subagent_type" = "statusline-setup" ] || [ -z "$subagent_type" ] ||
    [ "$subagent_type" = "Explore" ]; then
    debug_log step-log-section-before-spawn "forbidden type $subagent_type — deferring to operator-subagent-allowlist"
    exit 0
fi

# Map subagent_type → expected header in step log.
# planner-* → "## Plan" (session-log.md planner exception)
# all others → "## <subagent_type> Section"
case "$subagent_type" in
planner*)
    need="## Plan"
    ;;
*)
    need="## ${subagent_type} Section"
    ;;
esac

debug_log step-log-section-before-spawn "need=$need"

# Transcript readable guard — fail-open when transcript is unreadable.
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log step-log-section-before-spawn "fail-open: transcript unreadable"
    exit 0
fi

# Locate active step log from transcript.
log=$(session_log_from_transcript)

debug_log step-log-section-before-spawn "log=$log"

# build_spawn_breadcrumb <branch> <extra_jq_args...> — assembles the shared
# JSONL fields (ts/guard/session_id/transcript/mtime/sentinel/env) plus a
# caller-supplied `branch` tag, then fires guard_breadcrumb. Best-effort only.
build_and_fire_breadcrumb() {
    local branch="$1"
    shift
    local sid="${SESSION_ID:-unknown}"
    local bc_ts bc_mtime bc_sentinel bc_sentinel_path
    bc_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bc_mtime=$(stat -f '%m' "$TRANSCRIPT_PATH" 2>/dev/null || stat -c '%Y' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
    bc_sentinel_path="${CWD:-$PWD}/codegen/logging/.active"
    bc_sentinel=""
    [ -f "$bc_sentinel_path" ] && bc_sentinel=$(cat "$bc_sentinel_path" 2>/dev/null || true)
    local bc
    bc=$(jq -n \
        --arg ts "$bc_ts" \
        --arg guard "step-log-section-before-spawn" \
        --arg session_id "$sid" \
        --arg transcript_path "${TRANSCRIPT_PATH:-}" \
        --arg transcript_mtime "$bc_mtime" \
        --arg guard_resolved_log "${log:-}" \
        --arg active_sentinel_target "$bc_sentinel" \
        --arg codegen_log_path_env "${CODEGEN_LOG_PATH:-}" \
        --arg need "${need:-}" \
        --arg branch "$branch" \
        "$@" \
        '{ts: $ts, guard: $guard, session_id: $session_id, transcript_path: $transcript_path,
          transcript_mtime: ($transcript_mtime | tonumber), guard_resolved_log: $guard_resolved_log,
          active_sentinel_target: $active_sentinel_target, codegen_log_path_env: $codegen_log_path_env,
          need: $need, branch: $branch}' 2>/dev/null)
    guard_breadcrumb "$sid" "$bc"
}

# No log found → orchestrator skipped step-0 log creation.
if [ -z "$log" ]; then
    build_and_fire_breadcrumb "no-log"
    deny "BLOCKED: no step log found in transcript. Create the step log FIRST before spawning ${subagent_type}. Step 0 is non-negotiable: Write the step log skeleton, THEN insert the ## ${subagent_type} Section header, THEN spawn. A diagnostic breadcrumb was recorded at codegen/logging/.guard-diagnostics/${SESSION_ID:-unknown}.jsonl; if this recurs, attach it to the guard-false-positive pitch."
    exit 0
fi

# Distinguish absent (denied/never-created) from exists-but-unreadable (transient).
if [ ! -e "$log" ]; then
    build_and_fire_breadcrumb "never-created"
    deny "BLOCKED: step log was referenced in the transcript but was never created — a denied or failed Write leaves no file on disk. Create the step log for real before spawning. A diagnostic breadcrumb was recorded at codegen/logging/.guard-diagnostics/${SESSION_ID:-unknown}.jsonl; if this recurs, attach it to the guard-false-positive pitch."
    exit 0
fi
# Log exists but is momentarily unreadable (genuine transient) → fail-open.
if [ ! -r "$log" ]; then
    debug_log step-log-section-before-spawn "fail-open: log exists but not readable at $log"
    exit 0
fi

# Check that the expected header is present.
if grep -qF "$need" "$log" 2>/dev/null; then
    # Header present — additionally verify that the PRIOR stage's section has
    # real body content (not a stub with no output). This catches the case where
    # a subagent died before producing output and the orchestrator skips ahead.
    #
    # Role ordering: developer-* requires ## Plan, reviewer-* requires a
    # developer section, context-curator requires a reviewer section,
    # committer requires context-curator section. planner-* has no prior.
    prior_header=""
    case "$subagent_type" in
    developer-*)
        prior_header="## Plan"
        ;;
    reviewer-*)
        # Find any developer-* section header in the log.
        prior_header="$(grep -m1 '^## developer-' "$log" 2>/dev/null || true)"
        ;;
    context-curator)
        prior_header="$(grep -m1 '^## reviewer-' "$log" 2>/dev/null || true)"
        ;;
    committer)
        prior_header="## context-curator Section"
        ;;
    *)
        prior_header=""
        ;;
    esac

    if [ -n "$prior_header" ] && grep -qF "$prior_header" "$log" 2>/dev/null; then
        section_body=$(awk -v header="$prior_header" '
            found && /^## / { exit }
            found && /^### What I Learned/ { in_retro=1; next }
            in_retro && /^[[:space:]]*$/ { next }
            in_retro && /^[[:space:]]*[-*]/ { next }
            in_retro { in_retro=0 }
            found { print }
            $0 == header { found=1 }
        ' "$log" 2>/dev/null | grep -v '^[[:space:]]*$' | head -5)

        if [ -z "$section_body" ]; then
            deny "BLOCKED: '${prior_header}' exists in the step log but its body is empty — the prior stage produced no real content (subagent likely died). Recover: re-spawn the dead stage, produce real output, then retry. Do not skip a stage because the subagent died."
            exit 0
        fi
    fi

    debug_log step-log-section-before-spawn "allow: header present with body content"
    exit 0
fi

# Header absent → block and name the missing header. Full resolver-divergence
# breadcrumb: dual grep against both the guard-resolved log and the (possibly
# different) sentinel target, so a log-resolution mismatch is visible.
bc_sid="${SESSION_ID:-unknown}"
bc_sentinel_path="${CWD:-$PWD}/codegen/logging/.active"
bc_sentinel_target=""
[ -f "$bc_sentinel_path" ] && bc_sentinel_target=$(cat "$bc_sentinel_path" 2>/dev/null || true)
bc_grep_guard_log="no"
grep -qF "$need" "$log" 2>/dev/null && bc_grep_guard_log="yes"
bc_grep_sentinel_log="na"
if [ -n "$bc_sentinel_target" ] && [ "$bc_sentinel_target" != "$log" ] && [ -e "$bc_sentinel_target" ]; then
    bc_grep_sentinel_log="no"
    grep -qF "$need" "$bc_sentinel_target" 2>/dev/null && bc_grep_sentinel_log="yes"
fi
bc_mtime=$(stat -f '%m' "$TRANSCRIPT_PATH" 2>/dev/null || stat -c '%Y' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
bc=$(jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg guard "step-log-section-before-spawn" \
    --arg session_id "$bc_sid" \
    --arg transcript_path "${TRANSCRIPT_PATH:-}" \
    --arg transcript_mtime "$bc_mtime" \
    --arg guard_resolved_log "$log" \
    --arg active_sentinel_target "$bc_sentinel_target" \
    --arg codegen_log_path_env "${CODEGEN_LOG_PATH:-}" \
    --arg need "$need" \
    --arg grep_in_guard_log "$bc_grep_guard_log" \
    --arg grep_in_sentinel_log "$bc_grep_sentinel_log" \
    '{ts: $ts, guard: $guard, session_id: $session_id, transcript_path: $transcript_path,
      transcript_mtime: ($transcript_mtime | tonumber), guard_resolved_log: $guard_resolved_log,
      active_sentinel_target: $active_sentinel_target, codegen_log_path_env: $codegen_log_path_env,
      need: $need, grep_in_guard_log: $grep_in_guard_log, grep_in_sentinel_log: $grep_in_sentinel_log}' 2>/dev/null)
guard_breadcrumb "$bc_sid" "$bc"

deny "BLOCKED: missing section header in step log before spawning ${subagent_type}. Edit the step log to append '${need}' immediately before this Agent() call, then retry. A diagnostic breadcrumb was recorded at codegen/logging/.guard-diagnostics/${bc_sid}.jsonl; if this recurs, attach it to the guard-false-positive pitch."
exit 0
