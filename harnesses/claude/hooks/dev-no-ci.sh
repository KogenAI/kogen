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
#         make test / test-stacks / test-stacks-claude / test-all /
#         test-coverage / test-hermetic / bench (unowned, expensive, slow
#         full-suite targets)
#         bare `mix test` (no path argument)
#         `mix test` with only flags (no path)
#
#         …EXCEPT the app's own configured gate command, which is always
#         allowed — see "the gate command is DECLARED, never guessed" below.
#
# Allows: the app's configured gate command, read from
#         `<project>/.claude/gate-config.sh` via lib/gate-select.sh — the
#         SAME single source LoopGate.decide_gate/1 reads
#         `mix test test/path/file.exs` (specific test file paths)
#         `make install`, `make hook-parity`, `make enforce-registry-parity`,
#         `make harness-parity`, `make test-generator`,
#         `make rule-render-freshness` (narrow, targeted checks)
#
# The loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex) runs the full
# gate after the developer's turn on any FAILED hand-back; in loop mode the
# developer is directed to run the delegated gate command itself in-session
# and iterate until GREEN. Developers MUST NOT run the genuinely-unowned
# expensive full-suite targets above (real LLM calls, multi-minute) — those
# belong to the pre-deploy gate, not per-edit iteration. This hook enforces
# that across both platform Elixir invocations and direct shell-wrapper
# sessions because it's configured at ~/.claude/settings.json user-scope.
#
# ── the gate command is DECLARED, never guessed ─────────────────────────────
# What this hook enforces is a COST ("don't burn your turns on the expensive
# pipeline the loop already owns"), but the deny lists below express it as a
# set of NAMES. A name is not a cost, and the two drifted apart:
#
#   * orchestration_loop.ex build_prompt/2 threads the resolved gate command
#     verbatim into the developer's prompt ("Before handing back, run `<cmd>`
#     yourself … re-run until GREEN"). That command comes from
#     `<project>/.claude/gate-config.sh` GATE_COMMAND. When codegen's own
#     GATE_COMMAND moved to `make test`, this hook still denied `make test`
#     while allowing `make ci` — the system instructed the developer to run a
#     command and then blocked it, burning one of ~15 turn slots per attempt.
#   * the names are not even stable across repos: in codegen's own Makefile
#     `ci: test` is a pure alias, whereas in a GENERATED customer app
#     `make ci` is a strict superset of `make test` (credo/dialyzer/sobelow/
#     audit). Hard-coding either name is wrong in one of the two places.
#
# So the gate is resolved, not named: whatever `gate-select.sh` resolves for
# THIS project is allowed, and everything else in the deny lists stays denied.
# That tracks a changed GATE_COMMAND automatically, and it is correct in a
# generated app (gate `make ci` → allowed there, while `make test` stays
# denied there) and in codegen itself (gate `make test` → allowed here).
# No config file / empty GATE_COMMAND / unresolvable gate ⇒ nothing is
# allowed by this route and the deny lists apply exactly as before.
#
# Cost is still bounded — by developer-no-self-gate.sh, which counts gate
# invocations (`make ci`, `make test`, `mix test`) per session and caps them
# progress-bounded under CODEGEN_LOOP=1. That hook, not a name blacklist, is
# what stops a developer looping on the gate forever.

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

# ── Allow the app's own configured gate command ─────────────────────────────
# Resolved from <project>/.claude/gate-config.sh through lib/gate-select.sh —
# the SAME single source LoopGate.decide_gate/1 uses, so this hook and the
# command the loop threads into the prompt can never disagree. See the
# "gate command is DECLARED, never guessed" note in the header.
#
# Only worth resolving when the command could actually be denied below: every
# deny rule is anchored on a leading `make`/`mix`, so anything else skips the
# lookup entirely and this hook stays free on the common path.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*(make|mix)([[:space:]]|$)'; then
    # Resolve inside a subshell: gate_select_decide SOURCES the project's
    # gate-config.sh, and nothing in that file may leak into (or clobber) this
    # hook's own COMMAND/AGENT_TYPE/TOOL_NAME state.
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
        cmd_t="${COMMAND#"${COMMAND%%[![:space:]]*}"}"
        cmd_t="${cmd_t%"${cmd_t##*[![:space:]]}"}"
        gate_t="${gate_command#"${gate_command%%[![:space:]]*}"}"
        gate_t="${gate_t%"${gate_t##*[![:space:]]}"}"

        # The gate's own make target is, by definition, not "unowned expensive
        # work" for this project — drop it from the set we refuse to run
        # alongside the gate. A non-make gate (e.g. `mix test`, a script)
        # leaves the set whole.
        gate_target=""
        case "$gate_t" in
        make\ *)
            gate_target="${gate_t#make }"
            gate_target="${gate_target%% *}"
            ;;
        esac

        other_expensive=""
        for _t in ci-fast ci-cover predeploy llm llm-phoenix llm-all \
            test test-all test-hermetic test-coverage test-stacks \
            test-stacks-claude bench; do
            [ "$_t" = "$gate_target" ] && continue
            other_expensive="${other_expensive:+$other_expensive|}$_t"
        done

        # Allow when the command IS the gate command — bare, or with trailing
        # argv/redirection (`make test 2>&1 | tail -50`, `make test VERBOSE=1`)
        # — and no OTHER expensive target rides along in the same shell chain.
        # command_invokes is command-POSITION aware, so `make test && make
        # llm-all` is refused here and falls through to the deny rules, while a
        # mere mention in a pipeline argument does not block the allowance.
        if { [ "$cmd_t" = "$gate_t" ] || [ "${cmd_t#"$gate_t" }" != "$cmd_t" ]; } &&
            ! command_invokes "$COMMAND" '^make$' "^(${other_expensive})([[:space:]]|\$)"; then
            debug_log dev-no-ci "allow: matches configured gate command '$gate_t'"
            exit 0
        fi
    fi
fi

# Deny: make ci-fast / make ci-cover / make predeploy / make llm / make llm-phoenix / make llm-all
# (plain `make ci` is not listed: in a generated app it IS the configured gate
# and is allowed above; in codegen's own Makefile `ci: test` is a pure alias.)
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(ci-fast|ci-cover|predeploy|llm|llm-phoenix|llm-all)([[:space:]]|$)'; then
    deny "Dev MUST NOT run this gate command. Use this project's declared gate command${gate_command:+, \`$gate_command\`,} (from .claude/gate-config.sh) to iterate — see the loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex). Specific test files are OK: \`mix test test/path/file.exs\`. For the LLM suite specifically, use \`make llm-single FILE=<path>\` to iterate on one file."
    exit 0
fi

# Deny: full-suite/expensive targets (test, test-all, test-hermetic, test-coverage,
# test-stacks*, bench) — unowned by per-cycle iteration, owned by the loop's
# LoopGate (do_gate_loop/9 in orchestration_loop.ex) which runs after your turn.
if printf '%s' "$COMMAND" | grep -qE '^[[:space:]]*make[[:space:]]+(test|test-all|test-hermetic|test-coverage|test-stacks(-claude)?|bench)([[:space:]]|$)'; then
    deny "Dev MUST NOT run this full-suite target — it is slow and owned by the loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex), which runs after your turn. This project's gate command is${gate_command:+ \`$gate_command\`} (declared in .claude/gate-config.sh) and running THAT is allowed. Otherwise use targeted checks like \`mix test test/path/file.exs\` / \`make hook-parity\` / \`make enforce-registry-parity\` to iterate."
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
