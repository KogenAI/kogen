#!/usr/bin/env bash
# pitch-shipped-before-stop.sh — Stop hook: auto-ship pitch after commit.
#
# HOOK-MANIFEST:
# event: Stop
# matcher: *
# surface: user_global
# signal: CLAUDE_ROLE_FAMILY
# role: *
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# After the committer commits in a pitch-driven session, if the pitch is still
# in codegen/pitches/ready/, block the stop and instruct the orchestrator to
# move it to shipped/.
#
# Guard order:
#   1. STOP_HOOK_ACTIVE=true → exit (loop guard)
#   2. Retry-cap via /tmp/claude-autoship-guard-<SESSION_ID>.count (cap 2)
#   3. Role bypass: CLAUDE_ROLE=dashboard-build OR CODEGEN_NO_AUTOSHIP=1 → exit
#   4. Intent-question regex → exit (orchestrator asking user something)
#   5. Transcript unreadable → exit (fail-open)
#   6. session_log_from_transcript; extract slug from <ts>_<slug>_session.md filename
#      → empty slug = not a pitch-driven log → exit
#   7. No ## committer Section in log → exit (committer hasn't run yet)
#   8. ready/<slug>.md still exists → block with move instruction
#
# Bypass paths:
#   CLAUDE_ROLE=dashboard-build — dashboard manages shipped/ move itself post-merge
#   CODEGEN_NO_AUTOSHIP=1 — explicit operator suppression
#
# Fail-open on missing transcript or missing pitch path.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

session_id="${SESSION_ID:-unknown}"
counter_file="/tmp/claude-autoship-guard-${session_id}.count"

debug_log pitch-shipped-before-stop "session=$session_id"

# 1. Loop guard.
if [ "${STOP_HOOK_ACTIVE:-false}" = "true" ]; then
    debug_log pitch-shipped-before-stop "skip: stop_hook_active"
    exit 0
fi

# 2. Retry cap.
count=0
if [ -r "$counter_file" ]; then
    count=$(cat "$counter_file" 2>/dev/null || echo 0)
fi
case "$count" in
'' | *[!0-9]*) count=0 ;;
esac
if [ "$count" -ge 2 ]; then
    debug_log pitch-shipped-before-stop "skip: retry-cap count=$count"
    rm -f "$counter_file"
    exit 0
fi

# 3. Role bypass — dashboard-build or explicit env suppression.
_role=$(resolve_role)
if [ "$_role" = "dashboard-build" ] || [ -n "${CODEGEN_NO_AUTOSHIP:-}" ]; then
    debug_log pitch-shipped-before-stop "skip: role-bypass role=$_role CODEGEN_NO_AUTOSHIP=${CODEGEN_NO_AUTOSHIP:-}"
    exit 0
fi

# 4. Intent-question guard — orchestrator is asking the user something.
trimmed=$(printf '%s' "$LAST_ASSISTANT_MESSAGE" | sed -E 's/[[:space:]]+$//')
last_char="${trimmed: -1}"
intent_regex='[Ss]hould I|[Nn]eed clarification|[Bb]locked|[Ss]tuck|[Ww]aiting for|[Pp]lease confirm|[Ww]ant me to|[Cc]onfirm before'
if [ "$last_char" = "?" ] || printf '%s' "$LAST_ASSISTANT_MESSAGE" | grep -qE "$intent_regex"; then
    debug_log pitch-shipped-before-stop "skip: intent — last_char=$last_char"
    exit 0
fi

# 5. Transcript readable guard.
if [ -z "${TRANSCRIPT_PATH:-}" ] || [ ! -r "$TRANSCRIPT_PATH" ]; then
    debug_log pitch-shipped-before-stop "skip: no transcript"
    exit 0
fi

# 6. Active session log → extract slug from <ts>_<slug>_session.md filename.
log=$(session_log_from_transcript)
if [ -z "$log" ] || [ ! -r "$log" ]; then
    debug_log pitch-shipped-before-stop "skip: no step log"
    exit 0
fi

slug=$(basename "$log" | sed -E 's/^[0-9]{8}_[0-9]{6}_(.+)_session\.md$/\1/')
if [ -z "$slug" ] || [ "$slug" = "$(basename "$log")" ]; then
    debug_log pitch-shipped-before-stop "skip: no slug in log filename (free-form or multi-step log)"
    exit 0
fi

debug_log pitch-shipped-before-stop "slug=$slug log=$(basename "$log")"

# 7. Committer-section guard — only act after committer has committed.
if ! grep -qF "## committer Section" "$log" 2>/dev/null; then
    debug_log pitch-shipped-before-stop "skip: committer section absent"
    exit 0
fi

# 8. Check if this pitch (by slug) is still in ready/.
project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ready_path="$project_dir/codegen/pitches/ready/${slug}.md"

debug_log pitch-shipped-before-stop "ready_path=$ready_path"

if [ ! -f "$ready_path" ]; then
    debug_log pitch-shipped-before-stop "skip: pitch not in ready/ (already shipped or draft)"
    exit 0
fi

# Pitch still in ready/ after commit → block and instruct.
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

block "Pitch ${slug}.md was committed but is still in codegen/pitches/ready/. Move it to shipped/ before stopping: mv codegen/pitches/ready/${slug}.md codegen/pitches/shipped/${slug}.md (plain mv — pitch files are untracked, NEVER git mv). Then stop. (autoship-guard attempt ${count}/2)"
exit 0
