#!/bin/bash
# orchestrator-no-ci.sh — PreToolUse hook: deny gate commands for orchestrator.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: *
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Only enforces when AGENT_TYPE is empty AND AGENT_ID is empty (orchestrator level).
# Subagents (any non-empty AGENT_TYPE or AGENT_ID) pass through.
# ops/experiment/babysit mode (CLAUDE_ROLE) bypasses via resolve_role() — ops runs on live
# boxes, experiment is a standalone source-writable dev session, babysit dispatches the existing
# codegen-build --queue drain; all three need full gate-command access for inspection/dispatch.
#
# Blocks:
#   the project's own configured gate command (resolved, see below)
#   make ci / ci-cover / predeploy
#   make llm / llm-phoenix / llm-all / llm-phoenix-seed / llm-phoenix-validate
#        / llm-retry / llm-summary / llm-kill
#   bare mix test (no path), mix test flags-only, mix test --cover, mix coveralls*
#
# Allows (early-return before block regex):
#   make gate-status / gate-logs / gate-kill
#
# Gate commands run via the Elixir orchestration loop's LoopGate (non-interactive
# builds) or a SubagentStop hook (interactive-session fallback) after developer-*
# completes. The main-agent session MUST NOT run gate commands directly.
#
# ── the gate command is DECLARED, never guessed ─────────────────────────────
# The hardcoded `make ci` above is a NAME, and this hook is trying to enforce a
# ROLE BOUNDARY ("the outer session does not run the gate itself"). Those came
# apart the same way they did in dev-no-ci.sh, but in the opposite direction:
# codegen's Makefile:194 is `ci: test`, so `make ci` was denied here while
# `make test` — the identical target, and codegen's actual declared
# GATE_COMMAND — sailed straight through. The guard was bypassable by typing
# the other name for the same work.
#
# So the project's real gate is resolved through lib/gate-select.sh (the SAME
# single source LoopGate.decide_gate/1 and dev-no-ci.sh read) and denied here
# too. The two hooks now agree on what the gate IS; they simply disagree on who
# may run it — the developer may (dev-no-ci.sh allows it, because the loop
# threads that exact command into the developer's prompt), the outer session
# may not.
#
# This is ADDITIVE to the hardcoded list, never a replacement: in codegen the
# resolved gate is `make test` while `make ci` must STAY denied as its alias,
# and in a generated app the resolved gate IS `make ci`, already covered. An
# unresolvable gate (no config / empty GATE_COMMAND / malformed GATE_MODE)
# simply adds nothing — the hardcoded list still applies exactly as before.
#
# NOT affected by this: LoopGate's own gate run. It shells out via
# `System.cmd("bash", ["-c", gate_command], cd: project_dir)` (loop_gate.ex
# `:run_fn`), an Elixir subprocess — no PreToolUse hook fires on it. Builds do
# not route their gate through this hook and cannot be blocked by it.
#
# A session that genuinely needs to run the suite from the outer level has the
# documented bypasses — CLAUDE_ROLE=ops / experiment / babysit (see
# context/launcher-hook-matrix.md), which are checked before any of this.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
source "$(dirname "$0")/_role.sh"
parse_input

debug_log orchestrator-no-ci "tool=$TOOL_NAME agent_type=${AGENT_TYPE:-} agent_id=${AGENT_ID:-} cmd=${COMMAND:-}"

# ops/experiment/babysit bypasses: full gate-command access for inspection on
# live boxes (ops), standalone source-writable dev sessions (experiment), or
# the drain supervisor dispatching codegen-build (babysit).
_role=$(resolve_role)
case "$_role" in ops | experiment | babysit) exit 0 ;; esac

# Only enforce for orchestrator level (both AGENT_TYPE and AGENT_ID empty)
if [ -n "${AGENT_TYPE:-}" ] || [ -n "${AGENT_ID:-}" ]; then
    debug_log orchestrator-no-ci "skip: subagent (agent_type=${AGENT_TYPE:-} agent_id=${AGENT_ID:-})"
    exit 0
fi

# Only guard Bash tool
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

_deny_gate() {
    deny "orchestrator-no-ci: the main-agent session MUST NOT run gate commands directly. Gate runs via the loop (non-interactive builds) or a SubagentStop hook (interactive-session fallback) after developer-* completes. To inspect a running gate, use \`make gate-status\`. To trigger a gate, delegate to a developer-* subagent."
    exit 0
}

# Allowlist: gate-status / gate-logs / gate-kill — early return before block.
# Deliberately ahead of the resolved-gate block below: gate MANAGEMENT stays
# available to the outer session even in the pathological case of a project
# declaring one of these as its GATE_COMMAND.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(gate-status|gate-logs|gate-kill)([[:space:]]|$)'; then
    debug_log orchestrator-no-ci "allow: gate management command"
    exit 0
fi

# Block: the project's OWN declared gate command, whatever it is called.
# Resolved from <project>/.claude/gate-config.sh through lib/gate-select.sh —
# the same single source LoopGate.decide_gate/1 and dev-no-ci.sh use. See the
# "gate command is DECLARED, never guessed" note in the header.
#
# Resolved inside a subshell: gate_select_decide SOURCES the project's
# gate-config.sh, and nothing in that file may leak into (or clobber) this
# hook's own COMMAND / AGENT_TYPE / AGENT_ID / _role state.
gate_command=$(
    _gsel="$(dirname "$0")/lib/gate-select.sh"
    if [ -f "$_gsel" ]; then
        # shellcheck disable=SC1090
        source "$_gsel" 2>/dev/null || exit 0
        gate_select_decide "${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}" 2>/dev/null |
            sed -n 's/^gate=//p' | head -1
    fi
)

if [ -n "$gate_command" ]; then
    # Trim both sides so " make test " and "make test" compare equal.
    _cmd_t="${COMMAND#"${COMMAND%%[![:space:]]*}"}"
    _cmd_t="${_cmd_t%"${_cmd_t##*[![:space:]]}"}"
    _gate_t="${gate_command#"${gate_command%%[![:space:]]*}"}"
    _gate_t="${_gate_t%"${_gate_t##*[![:space:]]}"}"

    # Match the gate bare, or with trailing argv/redirection — `make test`,
    # `make test 2>&1 | tail -100`, `make test VERBOSE=1` are all the same run.
    if [ "$_cmd_t" = "$_gate_t" ] || [ "${_cmd_t#"$_gate_t" }" != "$_cmd_t" ]; then
        debug_log orchestrator-no-ci "DENY: configured gate command '$_gate_t'"
        deny "orchestrator-no-ci: \`$_gate_t\` is THIS project's declared gate command (.claude/gate-config.sh), and the main-agent session MUST NOT run the gate directly. It runs via the loop's LoopGate after developer-* completes. To inspect a running gate use \`make gate-status\`; to trigger one, delegate to a developer-* subagent. If you need the suite from an outer session, launch in ops/experiment mode (see context/launcher-hook-matrix.md)."
        exit 0
    fi
fi

# Block: make ci / ci-cover / predeploy
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(ci|ci-cover|predeploy)([[:space:]]|$|[[:space:]]*2>&1)'; then
    debug_log orchestrator-no-ci "DENY: make ci/ci-cover/predeploy"
    _deny_gate
fi

# Block: make llm / llm-phoenix / llm-all / llm-phoenix-seed / llm-phoenix-validate
#              / llm-retry / llm-summary / llm-kill
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(llm|llm-phoenix|llm-all|llm-phoenix-seed|llm-phoenix-validate|llm-retry|llm-summary|llm-kill)([[:space:]]|$)'; then
    debug_log orchestrator-no-ci "DENY: make llm*"
    _deny_gate
fi

# Block: coverage flags / mix coveralls (any variant)
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])--cover([[:space:]]|$)|\bcoveralls\.(html|json)\b|\bmix[[:space:]]+coveralls\b'; then
    debug_log orchestrator-no-ci "DENY: coverage command"
    _deny_gate
fi

# Block: bare mix test (no path)
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test[[:space:]]*$'; then
    debug_log orchestrator-no-ci "DENY: bare mix test"
    _deny_gate
fi

# Block: mix test with only flags (no path) — any mix test token is off-limits for orchestrator
# Orchestrator NEVER runs tests, even specific files (per roles/orchestrator.md line 11).
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test([[:space:]]|$)'; then
    debug_log orchestrator-no-ci "DENY: mix test (orchestrator must not run tests)"
    _deny_gate
fi

exit 0
