#!/bin/bash
# dev-no-ci.sh — PreToolUse hook: deny gate commands for developer-* agents.
#
# HOOK-MANIFEST:
# event: PreToolUse
# matcher: Bash
# surface: user_global
# signal: AGENT_TYPE
# role: developer-*
# harnesses: all
# registration only (hand-authored body) — the registry entry for this hook
# is `kind: registration`, which emits ONLY the settings.json wiring; the
# check logic below is NOT generated and is safe to hand-edit.
#
# Blocks: make ci-fast / ci-cover / predeploy / llm / llm-phoenix / llm-all
#         make test / test-stacks / test-stacks-claude / test-stacks-pi / test-all /
#         test-coverage / test-hermetic / bench (unowned, expensive, slow
#         full-suite targets)
#         bare `mix test` (no path argument)
#         `mix test` with only flags (no path)
#
# Allows: `mix test test/path/file.exs` (specific test file paths)
#         `make ci` (the loop's own gate command — the loop
#         threads this exact command into the developer's own prompt in
#         loop mode and expects the dev to run it in-session; see
#         orchestration_loop.ex build_prompt/2)
#         `make install`, `make hook-parity`, `make enforce-registry-parity`,
#         `make harness-parity`, `make test-generator`,
#         `make rule-render-freshness` (narrow, targeted checks)
#
# The loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex) runs the full
# gate after the developer's turn on any FAILED hand-back; in loop mode the
# developer is directed to run the delegated gate command (typically
# `make ci`) itself in-session and iterate until GREEN. Developers MUST NOT
# run the genuinely-unowned expensive full-suite targets above (real LLM
# calls, multi-minute) — those belong to the pre-deploy gate, not per-edit
# iteration. This hook enforces that across both platform Elixir invocations
# and direct shell-wrapper sessions because it's configured at
# ~/.claude/settings.json user-scope.

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log dev-no-ci "tool=$TOOL_NAME agent=$AGENT_TYPE cmd=$COMMAND"

# Only enforce for developer-* subagents.
case "$AGENT_TYPE" in
developer-*) ;;
*) exit 0 ;;
esac

# Only guard Bash tool.
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Deny: make ci-fast / make ci-cover / make predeploy / make llm / make llm-phoenix / make llm-all
# (make ci is the loop's own gate command — NOT denied; see
# orchestration_loop.ex build_prompt/2, which directs the dev to run this
# exact command in-session and iterate until GREEN.)
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(ci-fast|ci-cover|predeploy|llm|llm-phoenix|llm-all)([[:space:]]|$)'; then
    deny "Dev MUST NOT run this gate command. Use the loop's delegated gate command (typically \`make ci\`) to iterate — see the loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex). Specific test files are OK: \`mix test test/path/file.exs\`. For the LLM suite specifically, use \`make llm-single FILE=<path>\` to iterate on one file."
    exit 0
fi

# Deny: full-suite/expensive targets (test, test-all, test-hermetic, test-coverage,
# test-stacks*, bench) — unowned by per-cycle iteration, owned by the loop's
# LoopGate (do_gate_loop/9 in orchestration_loop.ex) which runs after your turn.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(test|test-all|test-hermetic|test-coverage|test-stacks(-claude|-pi)?|bench)([[:space:]]|$)'; then
    deny "Dev MUST NOT run this full-suite target — it is slow and owned by the loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex), which runs after your turn. Use targeted checks like \`mix test test/path/file.exs\` / \`make hook-parity\` / \`make enforce-registry-parity\` to iterate."
    exit 0
fi

# Deny: full-suite coverage formatters — unconditional (no single-file form).
# `mix coveralls` / coveralls.html / coveralls.json always run the full suite.
if printf '%s' "$COMMAND" | grep -qE '\bcoveralls\.(html|json)\b|\bmix[[:space:]]+coveralls\b'; then
    deny "Dev MUST NOT run coverage formatters (coveralls.html, coveralls.json, mix coveralls). Coverage runs the full suite — use the loop's delegated gate command instead."
    exit 0
fi

# Deny: bare `mix test --cover` (no path) — full-suite coverage.
# Allow `mix test --cover test/path/M_test.exs` as the optional single-file aid
# (reuse the same path-token check as the flags-only guard below).
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])--cover([[:space:]]|$)'; then
    has_path=$(printf '%s' "$COMMAND" | grep -oE '[^[:space:]]+' | grep -E '(/|\.exs$)' | head -1 || true)
    if [ -z "$has_path" ]; then
        deny "Bare \`mix test --cover\` runs full-suite coverage — dev MUST NOT. Use the loop's delegated gate command instead. A single file is OK: \`mix test --cover test/path/file.exs\`."
        exit 0
    fi
fi

# Deny: bare `mix test` (no path argument, no flags)
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test[[:space:]]*$'; then
    deny "Bare \`mix test\` runs full suite — dev MUST NOT. Use \`mix test test/path/file.exs\` for specific files."
    exit 0
fi

# Deny: `mix test` with only flags (no path) — e.g. `mix test --trace --max-cases 1`
# A test file path contains "/" or ends with ".exs". If no such token exists, it's a full-suite run.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*mix[[:space:]]+test[[:space:]]+--'; then
    has_path=$(printf '%s' "$COMMAND" | grep -oE '[^[:space:]]+' | grep -E '(/|\.exs$)' | head -1 || true)
    if [ -z "$has_path" ]; then
        deny "\`mix test\` with only flags (no path) runs full suite — dev MUST NOT. Specify a test file path, e.g. \`mix test test/path/file.exs\`."
        exit 0
    fi
fi

exit 0
