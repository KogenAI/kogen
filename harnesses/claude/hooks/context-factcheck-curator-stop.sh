#!/bin/bash
# context-factcheck-curator-stop.sh — SubagentStop hook for context-curator.
#
# HOOK-MANIFEST:
# event: SubagentStop
# matcher: context-curator
# surface: user_global
# signal: AGENT_TYPE
# role: context-curator
# harnesses: all
# GENERATED FROM shared/enforcement/registry.yaml — DO NOT EDIT
#
# Scans WORKING-TREE orientation docs (CLAUDE.md, AGENTS.md, PROJECT_CONTEXT.md,
# codegen/PROJECT_CONTEXT.md, context/*.md) for the two factcheck claim classes
# (named-path + count-anchor) and BLOCKS the curator so it fixes before
# yielding to the committer — the committer cannot Read/Edit context/*.md
# (subagent-read-discipline denies it), so a factcheck violation reaching the
# committer is an unfixable dead-end. This hook fires at the last role that
# CAN edit orientation docs, reading the working tree (not the staged blob),
# so it catches cross-file breaks too (e.g. doc A references a path deleted
# by an edit to file B this same cycle).
#
# Mirrors the claim-class scan logic of context-factcheck-guard.sh (the
# commit-time PreToolUse backstop for non-loop / direct / human commits,
# which is unchanged and kept). Divergence: this hook reads files from DISK
# (working tree), not `git show :<path>` (staged blob); and it `block`s
# (Stop-event JSON) instead of `deny`s (PreToolUse JSON).
#
# Claim class 1 — named-path probes:
#   For each working-tree orientation doc, extract backtick'd path-like
#   literals (containing at least one slash, matching known extensions).
#   If the path does not exist under repo_root → BLOCK.
#
# Claim class 2 — count anchors:
#   Match lines of the form: <!-- count: CMD -->NNN
#   CMD must use only allowlisted verbs (ls grep wc find cat sort uniq head tail)
#   and must not contain shell-injection tokens ($() backtick > >> ; && &).
#   Run CMD with cwd pinned to repo_root, compare integer output to NNN.
#   Mismatch → BLOCK. Probe infra fault (non-zero exit, non-integer output) → ALLOW.
#   Malformed NNN (non-integer) → BLOCK.
#   Disallowed verb or injection token → BLOCK.
#
# Allows:
#   - Non-context-curator stops
#   - STOP_HOOK_ACTIVE re-entry (loop guard — this hook itself may block)
#   - Any cwd outside a git repo or repo without a PROJECT_CONTEXT.md variant
#   - Docs absent from the working tree (deleted/never existed — nothing to scan)
#   - Named-path claims without a slash (bare basenames, out of grammar)
#   - Probe infra faults (fail-open for infrastructure errors only)

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log context-factcheck-curator-stop "agent=$AGENT_TYPE stop_active=$STOP_HOOK_ACTIVE"

# Loop guard: this hook may itself trigger a re-stop (block); avoid re-firing
# on the synthetic re-invocation.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# AGENT_TYPE gate — only run for context-curator.
case "$AGENT_TYPE" in
context-curator) ;;
*)
    exit 0
    ;;
esac

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. COMMAND is empty on SubagentStop events, so this
# is a harmless no-op guard kept for parity with sibling hooks.
is_codegen_log_write && exit 0

project_dir="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# Guard: must be inside a git repo.
if ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
fi

repo_root=$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$repo_root" ]; then
    exit 0
fi

# Detect layout (same priority as context-factcheck-guard / context-index-parity).
# Short-circuit here avoids the subprocess spawn below when there is
# obviously nothing to scan; the shared scan re-checks this itself too.
if [ ! -f "$repo_root/PROJECT_CONTEXT.md" ] && [ ! -f "$repo_root/codegen/PROJECT_CONTEXT.md" ]; then
    exit 0
fi

# Scan logic is shared with the in-loop Elixir factcheck step
# (OrchestrationLoop.run_factcheck_step) — see lib/context-factcheck-scan.sh.
# This hook stays a thin wrapper: run the scan, block on violations.
scan_out=$(bash "$(dirname "$0")/lib/context-factcheck-scan.sh" "$repo_root")
scan_rc=$?

if [ "$scan_rc" -eq 1 ] && [ -n "$scan_out" ]; then
    block "$scan_out Fix these in your working tree, then stop again."
fi
exit 0
