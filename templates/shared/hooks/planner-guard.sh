#!/bin/bash
# planner-guard.sh — PreToolUse hook for planner
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash|Write|Edit|MultiEdit|EnterPlanMode|ExitPlanMode
# surface: user_global
# signal: AGENT_TYPE
# role: planner
#
# Blocks file-creation, state-modifying shell commands, and Edit calls on
# non-session-log files when the active agent is "planner".
# The planner's only permitted write action is editing the session log
# under codegen/logging/. All other agents pass through unconditionally.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log planner-guard "tool=$TOOL_NAME agent=$AGENT_TYPE file=$FILE_PATH cmd=$COMMAND"

# Only gate planner; allow all other agents unconditionally
if [ "$AGENT_TYPE" != "planner" ]; then
    exit 0
fi

# ── Tool-level blocks ─────────────────────────────────────────────────────────

if [ "$TOOL_NAME" = "Write" ]; then
    deny "BLOCKED by planner-guard: tool Write forbidden for planner (planner never creates files — edit the session log via Edit)"
    exit 0
fi

if [ "$TOOL_NAME" = "MultiEdit" ]; then
    deny "BLOCKED by planner-guard: tool MultiEdit forbidden for planner (planner never mass-edits files)"
    exit 0
fi

if [ "$TOOL_NAME" = "EnterPlanMode" ]; then
    deny "BLOCKED by planner-guard: tool EnterPlanMode forbidden for planner (conflicts with orchestrator flow)"
    exit 0
fi

if [ "$TOOL_NAME" = "ExitPlanMode" ]; then
    deny "BLOCKED by planner-guard: tool ExitPlanMode forbidden for planner (conflicts with orchestrator flow)"
    exit 0
fi

# ── Edit path block ───────────────────────────────────────────────────────────
# Planner may only Edit session log files under codegen/logging/

if [ "$TOOL_NAME" = "Edit" ]; then
    # Allow only paths that START directly with codegen/logging/ (relative)
    # OR are absolute paths whose last two directory components are codegen/logging/
    # (i.e. /some/root/codegen/logging/file.md).
    # This prevents deep/fake/codegen/logging/ from matching as a relative path.
    relative_ok=0
    absolute_ok=0
    if printf '%s' "$FILE_PATH" | grep -qE '^codegen/logging/[^/]+\.md$'; then
        relative_ok=1
    fi
    if printf '%s' "$FILE_PATH" | grep -qE '^/.*/codegen/logging/[^/]+\.md$'; then
        absolute_ok=1
    fi
    if [ "$relative_ok" = "0" ] && [ "$absolute_ok" = "0" ]; then
        deny "BLOCKED by planner-guard: planner may only Edit session log files under codegen/logging/ (got: $FILE_PATH)"
        exit 0
    fi
fi

# ── Bash-pattern blocks ───────────────────────────────────────────────────────

if [ "$TOOL_NAME" = "Bash" ]; then

    # Deny any command containing relative path traversal (../).
    if printf '%s' "$COMMAND" | grep -qE '\.\./'; then
        deny "BLOCKED by planner-guard: relative path traversal (..) forbidden — use absolute paths only"
        exit 0
    fi

    # mix test — planner doesn't run tests
    if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+test\b'; then
        deny "BLOCKED by planner-guard: mix test is forbidden for planner (run gates after implementation, not during planning)"
        exit 0
    fi

    # mix ecto state-modifying commands
    if printf '%s' "$COMMAND" | grep -qE '\bmix[[:space:]]+ecto\.(migrate|reset|drop)\b'; then
        deny "BLOCKED by planner-guard: mix ecto.migrate/reset/drop is forbidden for planner (state-modifying)"
        exit 0
    fi

    # make ci / make llm variants — test/verification gates.
    # llm-phoenix-seed is blocked here because it mutates the seed DB, which is
    # a state-modifying operation. dev-no-ci.sh also blocks llm-phoenix (not seed)
    # for developers — policy is: developer can run seed rebuild explicitly, but
    # planner never should (planner investigates only, never mutates state).
    #
    # LLM allowlist rationale: the patterns blocked here (ci, ci-fast, llm,
    # llm-phoenix, llm-phoenix-seed, llm-summary, llm-retry, llm-kill) are ALL
    # verification/gate commands. Planner's job is investigation and planning,
    # never triggering CI or VE gates. Gates run via dev-gate.sh SubagentStop
    # hook after developer completes — planner must not short-circuit that flow.
    if printf '%s' "$COMMAND" | grep -qE '\bmake[[:space:]]+(ci|ci-fast|llm|llm-phoenix|llm-phoenix-seed|llm-summary|llm-retry|llm-kill)\b'; then
        deny "BLOCKED by planner-guard: make ci/llm/llm-phoenix/llm-phoenix-seed is forbidden for planner (verification gates run via dev-gate.sh hook on developer's SubagentStop; llm-phoenix-seed mutates state)"
        exit 0
    fi

    # git state-modification commands
    if printf '%s' "$COMMAND" | grep -qE '\bgit[[:space:]]+(add|commit|rm|mv|stash|reset|checkout[[:space:]]+[^[:space:]]+|branch[[:space:]]+(-[dD]|-m|-c|[^-]))\b'; then
        deny "BLOCKED by planner-guard: git state modification is forbidden for planner (committer owns git)"
        exit 0
    fi

    # rm / rmdir / mv on paths outside /tmp/ — prevent accidental file deletion
    if printf '%s' "$COMMAND" | grep -qE '\b(rm|rmdir)[[:space:]]+(-[rfRF]+[[:space:]]+)?[^/]'; then
        # Allow if target is relative path under /tmp/ — but can't tell at guard time,
        # so block all rm/rmdir that don't start with /tmp/ in the path argument
        if ! printf '%s' "$COMMAND" | grep -qE '\b(rm|rmdir)[[:space:]]+(-[rfRF]+[[:space:]]+)?/tmp/'; then
            deny "BLOCKED by planner-guard: rm/rmdir outside /tmp/ is forbidden for planner"
            exit 0
        fi
    fi

    if printf '%s' "$COMMAND" | grep -qE '\bmv[[:space:]]+'; then
        # Both source AND destination must be under /tmp/ or codegen/logging/.
        # Use printf '%s\n' to ensure sed sees a newline-terminated string (required for
        # macOS sed to process the final line correctly without an explicit $ anchor).
        src=$(printf '%s\n' "$COMMAND" | sed -nE 's/^mv[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
        dst=$(printf '%s\n' "$COMMAND" | sed -nE 's/^mv[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
        for mv_arg in "$src" "$dst"; do
            case "$mv_arg" in
            /tmp/* | codegen/logging/*) ;;
            *)
                deny "BLOCKED by planner-guard: mv argument \"$mv_arg\" outside /tmp/ or codegen/logging/ is forbidden for planner"
                exit 0
                ;;
            esac
        done
    fi

    # Redirect to file outside /tmp/ or codegen/logging/ — prevent writes via shell.
    # Strip stderr-redirect tokens (2>&1, 2>/dev/null) before inspection so they
    # don't get caught by the bare-redirect check.
    redirect_check=$(printf '%s' "$COMMAND" | sed -e 's/2>&1//g' -e 's|2>/dev/null||g')
    if printf '%s' "$redirect_check" | grep -qE '>[[:space:]]*[^/[:space:]]|>[[:space:]]*/'; then
        # Check if the redirect target is to codegen/logging/ or /tmp/
        if ! printf '%s' "$redirect_check" | grep -qE '>[[:space:]]*(codegen/logging/|/tmp/)'; then
            deny "BLOCKED by planner-guard: shell redirect to file outside /tmp/ or codegen/logging/ is forbidden for planner"
            exit 0
        fi
    fi

fi

exit 0
