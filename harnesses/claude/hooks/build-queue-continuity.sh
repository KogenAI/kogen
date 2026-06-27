#!/usr/bin/env bash
# build-queue-continuity.sh — Stop hook: block ending the session while a
# multi-pitch build queue has remaining pitches and the current pitch's gate
# did not fail.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# rationale: Deterministic Stop-hook backstop for build-queue-no-permission-asks — blocks ending a session while the build-queue manifest shows remaining pitches and the current pitch's gate did not fail.
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Decision tree:
#   1. STOP_HOOK_ACTIVE=true                           -> exit 0 (loop guard)
#   2. manifest codegen/gate-pending/build-queue.json absent -> exit 0 (not a queue)
#   3. manifest unparseable (jq fails / missing keys)  -> exit 0 (fail-open)
#   4. position >= len(slugs)                          -> exit 0 (queue exhausted)
#   5. gate verdict in {failed, inconclusive}          -> exit 0 (mid-queue halt)
#   6. otherwise (position < len, gate clear/empty)    -> BLOCK with next-slug reason

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/gate-result.sh"
parse_input

project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
debug_log build-queue-continuity "project_dir=$project_dir"

# 1. Loop guard.
if [ "${STOP_HOOK_ACTIVE:-false}" = "true" ]; then
    debug_log build-queue-continuity "skip: stop_hook_active"
    exit 0
fi

# Investigative-mode skip: this build-runtime gate enforces ONLY in build mode
# (empty role). Skip (exit 0) for any non-empty investigative role (shape/debug/
# ops/experiment) — mirrors signal: CLAUDE_ROLE_FAMILY. Inverse of pitch-format-validator.
source "$(dirname "$0")/_role.sh"
role=$(resolve_role)
if [ -n "$role" ]; then
    debug_log build-queue-continuity "skip: investigative role=$role"
    exit 0
fi

# 2. Manifest presence.
manifest="$project_dir/codegen/gate-pending/build-queue.json"
if [ ! -f "$manifest" ]; then
    debug_log build-queue-continuity "skip: no queue manifest"
    exit 0
fi

# 3. Parse manifest (fail-open on jq error or missing key).
slugs_len=$(jq -r '(.slugs | length) // empty' "$manifest" 2>/dev/null)
position=$(jq -r 'if (.position|type)=="number" then .position else empty end' "$manifest" 2>/dev/null)
if [ -z "$slugs_len" ] || [ -z "$position" ]; then
    debug_log build-queue-continuity "skip: manifest unparseable (len=$slugs_len pos=$position)"
    exit 0
fi

# 4. Queue exhausted.
if [ "$position" -ge "$slugs_len" ]; then
    debug_log build-queue-continuity "skip: queue exhausted ($position/$slugs_len)"
    exit 0
fi

# 5. Gate-failure escape (mid-queue halt is legitimate).
verdict=$(gate_result_verdict "$project_dir")
if [ "$verdict" = "failed" ] || [ "$verdict" = "inconclusive" ]; then
    debug_log build-queue-continuity "skip: gate verdict=$verdict — mid-queue halt allowed"
    exit 0
fi

# 6. Remaining pitches + gate not failed -> block.
remaining=$((slugs_len - position))
next_slug=$(jq -r --argjson p "$position" '.slugs[$p] // "unknown"' "$manifest" 2>/dev/null)
debug_log build-queue-continuity "BLOCK: next=$next_slug remaining=$remaining"
block "build-queue-continuity: ${remaining} queued pitch(es) remain (next: ${next_slug}). Build-queue continuity is autonomous — do NOT stop and do NOT ask permission. Create the next pitch's session log and begin its cycle now. (The only legitimate mid-queue stop is a gate failure, which this hook already allows.)"
exit 0
