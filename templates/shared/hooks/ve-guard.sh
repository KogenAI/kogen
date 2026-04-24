#!/bin/bash
# ve-guard.sh — PreToolUse hook for verification-engineer
#
# Blocks destructive shell patterns and forbidden tools when the active agent
# is "verification-engineer". All other agents pass through unconditionally.
#
# Monitor is PERMITTED (needed for long-gate recipe: run_in_background + Monitor + Read).
# run_in_background is PERMITTED only for: make llm, make llm-phoenix, make llm-phoenix-seed
# (seed rebuild only when COMBOBULATE_VE_GATE starts with rebuild-seed-then).
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (Claude Code PreToolUse convention)

set -euo pipefail

input=$(cat)

# Parse fields from PreToolUse stdin JSON
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
agent_name=$(printf '%s' "$input" | jq -r '.agent_name // ""')

# Debug logging (opt-in via per-script var or the unified COMBOBULATE_HOOKS_DEBUG flag)
if [ -n "${COMBOBULATE_VE_DEBUG:-}" ] || [ -n "${COMBOBULATE_HOOKS_DEBUG:-}" ]; then
    printf '%s tool=%s agent=%s cmd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$tool_name" "$agent_name" "$command" \
        >>/tmp/ve-guard-debug.log 2>/dev/null || true
fi

# Only gate verification-engineer; allow all other agents unconditionally
if [ "$agent_name" != "verification-engineer" ]; then
    exit 0
fi

# ── Tool-level blocks ─────────────────────────────────────────────────────────

if [ "$tool_name" = "Write" ]; then
    printf 'BLOCKED by ve-guard: tool Write forbidden for verification-engineer — you run gates and report, never write files\n' >&2
    exit 2
fi

# Edit is only permitted for appending to session log files — never for source code
if [ "$tool_name" = "Edit" ]; then
    if ! printf '%s' "$file_path" | grep -qE 'codegen/logging/.*\.md$'; then
        printf 'BLOCKED by ve-guard: Edit forbidden for verification-engineer on %s — VE only appends to session logs under codegen/logging/. Report failures; delegate fixes to developer.\n' "$file_path" >&2
        exit 2
    fi
fi

# ── Read-path block ───────────────────────────────────────────────────────────

if [ "$tool_name" = "Read" ]; then
    if printf '%s' "$file_path" | grep -qE '^/private/tmp/claude-[^/]+/tasks/'; then
        printf 'BLOCKED by ve-guard: VE may not spelunk other agents'\'' task dirs (%s)\n' \
            "$file_path" >&2
        exit 2
    fi
fi

# ── Bash-pattern blocks ───────────────────────────────────────────────────────

if [ "$tool_name" = "Bash" ]; then

    # sleep <number> — background-loop sentinel
    if printf '%s' "$command" | grep -qE 'sleep[[:space:]]+[0-9]'; then
        printf 'BLOCKED by ve-guard: sleep N is forbidden for verification-engineer (use timeout: parameter on the Bash call)\n' >&2
        exit 2
    fi

    # pgrep — process-polling sentinel
    if printf '%s' "$command" | grep -qE '\bpgrep\b'; then
        printf 'BLOCKED by ve-guard: pgrep is forbidden for verification-engineer (do not poll for running processes)\n' >&2
        exit 2
    fi

    # nohup — detach sentinel
    if printf '%s' "$command" | grep -qE '\bnohup\b'; then
        printf 'BLOCKED by ve-guard: nohup is forbidden for verification-engineer (run commands synchronously)\n' >&2
        exit 2
    fi

    # until <poll-form>; do — polling loop
    if printf '%s' "$command" | grep -qE 'until[[:space:]]+!?[[:space:]]*(ps[[:space:]]+aux|pgrep|grep)'; then
        printf 'BLOCKED by ve-guard: until-poll loop is forbidden for verification-engineer (use timeout: parameter)\n' >&2
        exit 2
    fi

    # while ... ; do — background-loop sentinel
    if printf '%s' "$command" | grep -qE 'while[[:space:]]+.*[[:space:]]*;[[:space:]]*do'; then
        printf 'BLOCKED by ve-guard: while loop is forbidden for verification-engineer (run commands synchronously)\n' >&2
        exit 2
    fi

    # Seed-rebuild commands — only permitted when env var carries the right prefix
    ve_gate="${COMBOBULATE_VE_GATE:-}"

    if printf '%s' "$command" | grep -qE 'rm[[:space:]]+-rf?[[:space:]]+~?/?\.combobulate_phoenix_seed'; then
        if [[ "$ve_gate" != rebuild-seed-then* ]]; then
            printf 'BLOCKED by ve-guard: seed wipe is forbidden for verification-engineer — return INCONCLUSIVE ⚠️ seed-suspect; orchestrator owns seed lifecycle\n' >&2
            exit 2
        fi
    fi

    if printf '%s' "$command" | grep -qE 'make[[:space:]]+llm-phoenix-seed'; then
        if [[ "$ve_gate" != rebuild-seed-then* ]]; then
            printf 'BLOCKED by ve-guard: make llm-phoenix-seed is forbidden for verification-engineer — return INCONCLUSIVE ⚠️ seed-suspect; orchestrator owns seed lifecycle\n' >&2
            exit 2
        fi
    fi

    # run_in_background guard — only permitted for the two long LLM gates and seed-rebuild
    run_bg=$(printf '%s' "$input" | jq -r '.tool_input.run_in_background // false')

    if [ "$run_bg" = "true" ]; then
        case "$command" in
        "make llm" | "make llm "* | "make llm-phoenix" | "make llm-phoenix "*)
            :
            ;;
        "make llm-phoenix-seed" | "make llm-phoenix-seed "*)
            if [[ "${COMBOBULATE_VE_GATE:-}" != rebuild-seed-then* ]]; then
                printf 'BLOCKED by ve-guard: make llm-phoenix-seed requires COMBOBULATE_VE_GATE=rebuild-seed-then\n' >&2
                exit 2
            fi
            ;;
        *)
            printf 'BLOCKED by ve-guard: run_in_background allowed only for `make llm`, `make llm-phoenix`, and seed-rebuild — got: %s\n' "$command" >&2
            exit 2
            ;;
        esac
    fi

fi

exit 0
