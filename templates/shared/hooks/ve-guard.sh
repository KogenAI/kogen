#!/bin/bash
# ve-guard.sh — PreToolUse hook for verification-engineer
#
# Blocks destructive shell patterns and forbidden tools when the active agent
# is "verification-engineer". All other agents pass through unconditionally.
#
# Monitor is PERMITTED (needed for long-gate recipe: run_in_background + Monitor + Read).
# run_in_background is PERMITTED only for: make llm, make llm-phoenix, make llm-phoenix-seed
# (seed rebuild only when COMBOBULATE_VE_GATE starts with rebuild-seed-then).

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log ve-guard "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only gate verification-engineer; allow all other agents unconditionally
if [ "$AGENT_TYPE" != "verification-engineer" ]; then
    exit 0
fi

# ── Tool-level blocks ─────────────────────────────────────────────────────────

if [ "$TOOL_NAME" = "Write" ]; then
    deny "BLOCKED by ve-guard: tool Write forbidden for verification-engineer — you run gates and report, never write files"
    exit 0
fi

# Edit is only permitted for appending to session log files — never for source code
if [ "$TOOL_NAME" = "Edit" ]; then
    if ! printf '%s' "$FILE_PATH" | grep -qE 'codegen/logging/.*\.md$'; then
        deny "BLOCKED by ve-guard: Edit forbidden for verification-engineer on $FILE_PATH — VE only appends to session logs under codegen/logging/. Report failures; delegate fixes to developer."
        exit 0
    fi
fi

# ── Read-path block ───────────────────────────────────────────────────────────

if [ "$TOOL_NAME" = "Read" ]; then
    if printf '%s' "$FILE_PATH" | grep -qE '^/private/tmp/claude-[^/]+/tasks/'; then
        deny "BLOCKED by ve-guard: VE may not spelunk other agents' task dirs ($FILE_PATH)"
        exit 0
    fi
fi

# ── Bash-pattern blocks ───────────────────────────────────────────────────────

if [ "$TOOL_NAME" = "Bash" ]; then

    # sleep <number> — background-loop sentinel
    if printf '%s' "$COMMAND" | grep -qE 'sleep[[:space:]]+[0-9]'; then
        deny "BLOCKED by ve-guard: sleep N is forbidden for verification-engineer (use timeout: parameter on the Bash call)"
        exit 0
    fi

    # pgrep — process-polling sentinel
    if printf '%s' "$COMMAND" | grep -qE '\bpgrep\b'; then
        deny "BLOCKED by ve-guard: pgrep is forbidden for verification-engineer (do not poll for running processes)"
        exit 0
    fi

    # nohup — detach sentinel
    if printf '%s' "$COMMAND" | grep -qE '\bnohup\b'; then
        deny "BLOCKED by ve-guard: nohup is forbidden for verification-engineer (run commands synchronously)"
        exit 0
    fi

    # until <poll-form>; do — polling loop
    if printf '%s' "$COMMAND" | grep -qE 'until[[:space:]]+!?[[:space:]]*(ps[[:space:]]+aux|pgrep|grep)'; then
        deny "BLOCKED by ve-guard: until-poll loop is forbidden for verification-engineer (use timeout: parameter)"
        exit 0
    fi

    # while ... ; do — background-loop sentinel
    if printf '%s' "$COMMAND" | grep -qE 'while[[:space:]]+.*[[:space:]]*;[[:space:]]*do'; then
        deny "BLOCKED by ve-guard: while loop is forbidden for verification-engineer (run commands synchronously)"
        exit 0
    fi

    # Seed-rebuild commands — only permitted when env var carries the right prefix
    ve_gate="${COMBOBULATE_VE_GATE:-}"

    if printf '%s' "$COMMAND" | grep -qE 'rm[[:space:]]+-rf?[[:space:]]+~?/?\.combobulate_phoenix_seed'; then
        if [[ "$ve_gate" != rebuild-seed-then* ]]; then
            deny "BLOCKED by ve-guard: seed wipe is forbidden for verification-engineer — return INCONCLUSIVE ⚠️ seed-suspect; orchestrator owns seed lifecycle"
            exit 0
        fi
    fi

    if printf '%s' "$COMMAND" | grep -qE 'make[[:space:]]+llm-phoenix-seed'; then
        if [[ "$ve_gate" != rebuild-seed-then* ]]; then
            deny "BLOCKED by ve-guard: make llm-phoenix-seed is forbidden for verification-engineer — return INCONCLUSIVE ⚠️ seed-suspect; orchestrator owns seed lifecycle"
            exit 0
        fi
    fi

    # run_in_background guard — only permitted for the two long LLM gates and seed-rebuild
    run_bg=$(printf '%s' "$RAW_INPUT" | jq -r '.tool_input.run_in_background // false')

    if [ "$run_bg" = "true" ]; then
        case "$COMMAND" in
        "make llm" | "make llm "* | "make llm-phoenix" | "make llm-phoenix "*)
            :
            ;;
        "make llm-phoenix-seed" | "make llm-phoenix-seed "*)
            if [[ "${COMBOBULATE_VE_GATE:-}" != rebuild-seed-then* ]]; then
                deny "BLOCKED by ve-guard: make llm-phoenix-seed requires COMBOBULATE_VE_GATE=rebuild-seed-then"
                exit 0
            fi
            ;;
        *)
            deny "BLOCKED by ve-guard: run_in_background allowed only for \`make llm\`, \`make llm-phoenix\`, and seed-rebuild — got: $COMMAND"
            exit 0
            ;;
        esac
    fi

fi

exit 0
