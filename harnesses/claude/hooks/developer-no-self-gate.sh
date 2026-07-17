#!/bin/bash
# developer-no-self-gate.sh — PreToolUse Bash hook for developer-* agents.
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
# Counts CI/test invocations per session. Ceiling is MODE-DEPENDENT: legacy
# (non-loop) mode caps at a raw count of 3; under the Elixir loop
# (CODEGEN_LOOP=1) the cap is progress-bounded (a gate re-run is allowed as
# long as the working tree changed since the last run) with a hard ceiling
# of 15 regardless of progress. Once a cap fires, denies further attempts
# and instructs the dev to stop and hand back — the loop's LoopGate
# (do_gate_loop/9 in orchestration_loop.ex) owns the full gate run after the
# dev's turn.
#
# Tracked patterns (matched at the COMMAND-WORD position via
# command_invokes(), never against the raw line — a mention of "mix test"
# inside a grep pattern or echo string is not an invocation and never
# enters the counted/gated path):
#   mix test, mix credo, mix format
#   make ci, make test

set -u

source "$(dirname "$0")/lib/hooks-lib.sh"
parse_input

debug_log developer-no-self-gate "tool=$TOOL_NAME agent=$AGENT_TYPE"

# Only gate developer-* variants
case "$AGENT_TYPE" in
developer-phoenix-backend | developer-phoenix-frontend | developer-static) ;;
*)
    exit 0
    ;;
esac

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# A codegen-log write narrates gated phrases in its heredoc body; it is never
# the gated action itself. Bypass before any phrase match or counter increment.
if is_codegen_log_write; then
    exit 0
fi

# Check if command matches a self-gate pattern — command-word position only,
# so `grep -n "mix test" README.md` or `echo "run make ci first"` never enter
# the counted path (they mention the phrase, they do not invoke it).
if ! command_invokes "$COMMAND" '^mix$' '^(test|credo|format)($|[[:space:]])' &&
    ! command_invokes "$COMMAND" '^make$' '^(ci|test)($|[[:space:]])'; then
    exit 0
fi

# mix credo is cheap and required before handoff — bypass the cap entirely.
# Only mix test / make ci / make test / mix format remain capped.
if command_invokes "$COMMAND" '^mix$' '^credo($|[[:space:]])' &&
    ! command_invokes "$COMMAND" '^make$' '^(ci|test)($|[[:space:]])' &&
    ! command_invokes "$COMMAND" '^mix$' '^test($|[[:space:]])'; then
    exit 0
fi

session_id="${SESSION_ID:-unknown}"

# ── Loop-mode: progress-bounded self-verify ─────────────────────────────────
# Under the Elixir loop (CODEGEN_LOOP=1) the developer runs the delegated
# gate itself, in its own warm session, and must keep fixing red until it is
# green. A raw count-of-3 cap would wedge that workflow on a real multi-red
# fix cycle. Instead, bound retries by PROGRESS: allow a gate re-run whenever
# the working tree's content signature changed since the last gate run (the
# dev made an edit); deny on a pure spin (signature unchanged — nothing was
# fixed, re-running the gate again cannot help). A hard ceiling (15) still
# backstops runaway loops regardless of continued progress.
if [ "${CODEGEN_LOOP:-}" = "1" ]; then
    cwd="${CWD:-$PWD}"
    signature=$(cd "$cwd" 2>/dev/null && git ls-files -oc --exclude-standard 2>/dev/null | sort | xargs shasum 2>/dev/null | shasum 2>/dev/null | cut -d' ' -f1)

    sig_file="/tmp/codegen-self-gate-${session_id}.sig"

    # CODEGEN_RESUME_ATTEMPT is set by the loop on a warm-resume transient
    # retry (same claude session_id as the attempt that dropped). Without
    # this, a developer that drops mid-gate resumes into an UNCHANGED tree
    # (it never got to make the fixing edit) and would be denied here as a
    # "pure spin" even though nothing was actually re-run yet. A NEW resume
    # token vs. the last-seen one is treated as a fresh first-run: allow,
    # and reset the stored signature — the hard ceiling below still applies
    # regardless, so this only removes the false-positive, not the bound.
    resume_token="${CODEGEN_RESUME_ATTEMPT:-}"
    prev_resume_token=""

    prev_sig=""
    prev_count=0
    if [ -r "$sig_file" ]; then
        prev_sig=$(sed -n '1p' "$sig_file" 2>/dev/null || printf '')
        prev_count=$(sed -n '2p' "$sig_file" 2>/dev/null || printf '0')
        prev_resume_token=$(sed -n '3p' "$sig_file" 2>/dev/null || printf '')
    fi
    case "$prev_count" in
    '' | *[!0-9]*) prev_count=0 ;;
    esac

    new_count=$((prev_count + 1))

    debug_log developer-no-self-gate "loop-mode session=$session_id count=$new_count sig=$signature prev_sig=$prev_sig resume_token=$resume_token prev_resume_token=$prev_resume_token"

    if [ "$new_count" -ge 15 ]; then
        printf '%s\n%s\n%s\n' "$signature" "$new_count" "$resume_token" >"$sig_file"
        deny "BLOCKED by developer-no-self-gate: hard ceiling (15 gate self-verify runs) reached this session. Counted commands: mix test, mix format, make ci, make test (bare 'mix credo' alone is exempt). Counter is session-wide across ALL calls, not just re-runs after edits — hand back to the loop rather than continuing to retry."
        exit 0
    fi

    if [ -n "$resume_token" ] && [ "$resume_token" != "$prev_resume_token" ]; then
        # First gate check under a NEW resume token → treat as a fresh run,
        # not a spin, regardless of the tree signature.
        printf '%s\n%s\n%s\n' "$signature" "$new_count" "$resume_token" >"$sig_file"
        exit 0
    fi

    if [ -z "$prev_sig" ] || [ "$signature" != "$prev_sig" ]; then
        # First run, or the tree changed since the last gate run → progress.
        printf '%s\n%s\n%s\n' "$signature" "$new_count" "$resume_token" >"$sig_file"
        exit 0
    fi

    # Signature unchanged → pure spin, nothing was fixed since the last run.
    printf '%s\n%s\n%s\n' "$signature" "$new_count" "$resume_token" >"$sig_file"
    deny "BLOCKED by developer-no-self-gate: the gate command (mix test/format, make ci/test) was re-run with NO change to the working tree since the last run — that cannot fix anything. Make an edit that addresses the failure, or hand back to the loop if you are stuck."
    exit 0
fi

# ── Legacy (non-loop) mode: raw count-of-3 cap ──────────────────────────────
counter_file="/tmp/codegen-self-gate-${session_id}.count"

# Read current count
count=0
if [ -r "$counter_file" ]; then
    count=$(cat "$counter_file" 2>/dev/null || echo 0)
fi
case "$count" in
'' | *[!0-9]*) count=0 ;;
esac

# Increment
count=$((count + 1))
printf '%s' "$count" >"$counter_file"

debug_log developer-no-self-gate "session=$session_id count=$count cmd=$COMMAND"

if [ "$count" -ge 3 ]; then
    deny "BLOCKED by developer-no-self-gate: return control to orchestrator. You have run mix test/format or make ci/test $count times in this session (bare 'mix credo' alone is exempt); the cap is session-wide, not per-edit. Complete your implementation and stop — the loop's LoopGate runs the full gate after your turn."
    exit 0
fi

exit 0
