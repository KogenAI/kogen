#!/usr/bin/env bash
# curator-consumption-scan.sh — asserts a cycle's captured learnings were
# CONSUMED (routed into a durable doc, or explicitly recorded as dropped),
# not merely captured. Companion to context-index-parity-scan.sh /
# context-factcheck-scan.sh, run as the third leg of
# OrchestrationLoop.default_curator_doc_scan/2.
#
# Usage: curator-consumption-scan.sh <repo_root> <cycle_log>
#
# Exit 0: clean — either nothing captured this cycle, or the curator routed
#         at least one learning into a durable doc, or recorded a drop.
# Exit 1: violations — learnings were captured but neither routed nor
#         recorded as dropped. Prints one message naming captured/routed/
#         unaccounted-for counts.
# Exit 2: usage error (missing args).
#
# Definitions:
#   "captured"  — count of {"ev":"learned"} events in <cycle_log> whose
#                 .role is NOT context-curator (upstream roles only —
#                 developer/reviewer).
#   "routed"    — the working tree (uncommitted, vs HEAD) OR untracked-file
#                 set contains at least one path matching
#                 ^(context/[^/]+\.md|shared/rules/.*\.md)$
#
#                 NOTE: curator edits are conventionally spelled
#                 codegen/rules/** in docs/rules, but codegen/rules is a
#                 symlink into shared/rules/ and /codegen/ is gitignored —
#                 git NEVER reports a path spelled codegen/rules/** (git
#                 check-ignore on that spelling errors "pathspec is beyond a
#                 symbolic link"). git diff/ls-files output is always spelled
#                 shared/rules/**. A filter on the codegen/rules/** spelling
#                 would match nothing, ever, and this scan would pass
#                 vacuously on every routed learning. This filter MUST stay
#                 on the shared/rules/** spelling.
#   "dropped"   — count of {"ev":"learned"} events whose .role IS
#                 context-curator (the curator's own record of why a
#                 captured learning was not routed).
#
# Clean iff captured == 0, OR routed has >=1 match, OR dropped >= 1.
# (dropped need not equal captured exactly — a single curator learned event
# can cover multiple drops; requiring 1:1 would be brittle busywork the
# pitch explicitly does not ask for.)
#
# Fail-closed on a present-but-unreadable log (path given but file missing /
# not valid JSONL) — exit 1, naming the reason. This is the "cannot resolve
# the log" case: a check that cannot see the truth must not pass.

set -uo pipefail

repo_root="${1:-}"
cycle_log="${2:-}"

if [ -z "$repo_root" ] || [ -z "$cycle_log" ]; then
    printf 'curator-consumption-scan: usage: curator-consumption-scan.sh <repo_root> <cycle_log>\n' >&2
    exit 2
fi

if [ ! -f "$cycle_log" ]; then
    printf 'curator-consumption-scan: cycle log not found at %s — cannot verify learnings were consumed.\n' "$cycle_log"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'curator-consumption-scan: jq not found on PATH — cannot verify learnings were consumed.\n' >&2
    exit 1
fi

captured_err=$(mktemp)
trap 'rm -f "$captured_err"' EXIT
captured=$(jq -s '[.[] | select(.ev == "learned" and .role != "context-curator")] | length' "$cycle_log" 2>"$captured_err")
captured_rc=$?
if [ "$captured_rc" -ne 0 ]; then
    printf 'curator-consumption-scan: jq failed to parse %s as JSONL (exit %s): %s\n' "$cycle_log" "$captured_rc" "$(cat "$captured_err")"
    exit 1
fi

if [ "$captured" -eq 0 ]; then
    exit 0
fi

dropped_err=$(mktemp)
trap 'rm -f "$captured_err" "$dropped_err"' EXIT
dropped=$(jq -s '[.[] | select(.ev == "learned" and .role == "context-curator")] | length' "$cycle_log" 2>"$dropped_err")
dropped_rc=$?
if [ "$dropped_rc" -ne 0 ]; then
    printf 'curator-consumption-scan: jq failed to parse %s as JSONL (exit %s): %s\n' "$cycle_log" "$dropped_rc" "$(cat "$dropped_err")"
    exit 1
fi

if [ "$dropped" -gt 0 ]; then
    exit 0
fi

routed=0

if git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    resolved_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$resolved_root" ]; then
        diff_out=$(git -C "$resolved_root" diff --name-only HEAD 2>/dev/null || true)
        untracked_out=$(git -C "$resolved_root" ls-files --others --exclude-standard 2>/dev/null || true)
        combined=$(printf '%s\n%s\n' "$diff_out" "$untracked_out")
        if printf '%s\n' "$combined" | grep -E '^(context/[^/]+\.md|shared/rules/.*\.md)$' >/dev/null 2>&1; then
            routed=1
        fi
    fi
fi

if [ "$routed" -eq 1 ]; then
    exit 0
fi

printf 'curator-consumption-scan: this cycle captured %s learning(s) via ev:learned, routed 0 into context/**.md or shared/rules/**.md, and recorded 0 dropped-learning entries. Either route at least one learning into a durable doc, or record each dropped learning with its reason via: codegen-log append context-curator --learned "[local] <what was dropped and why>" --slug <slug>\n' "$captured"
exit 1
