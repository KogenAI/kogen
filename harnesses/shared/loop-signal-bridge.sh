#!/usr/bin/env bash
# loop-signal-bridge.sh — shared INT->group-TERM->re-wait boundary for the
# four bash callers that spawn the Elixir orchestration loop as a
# job-controlled child: harnesses/claude/dispatch.sh (single-build) and
# the `--queue` leg of harnesses/claude/claude-build.sh (multi-pitch
# drain). Sourced, never executed directly.
#
# Why this exists: SIGINT is uncatchable inside the BEAM
# (`:os.set_signal/2` excludes :sigint on every OTP release — see
# test_harness/lib/codegen_test_harness/build_signal_handler.ex moduledoc),
# so a bash parent must stay alive after spawning the loop, trap INT/TERM
# itself, and forward SIGTERM (which IS catchable) to the child's process
# group. Before this helper existed, only the two dispatch.sh scripts did
# this; the two queue launchers instead directly `exec`'d the loop, which
# replaces the shell and hands terminal Ctrl-C straight to Erlang's
# uncatchable break handler — orphaning beam.smp. This helper is the ONE
# owner of that lifecycle for all four callers.
#
# Usage (sourced, then call):
#   source loop-signal-bridge.sh
#   run_supervised_loop <cmd...>
#   rc=$?
#
# Contract:
#   - NEVER `exec`s — spawns the child job-controlled (`set -m`) and stays
#     alive to trap+forward, then returns the child's own terminal exit
#     status (or 128+signal on a signal death, same convention the caller
#     already decodes).
#   - First INT/TERM (before the child even exists): returns 130 immediately,
#     no spawn.
#   - First INT/TERM (after the child exists): forwards SIGTERM to the
#     child's process group (`kill -TERM -<pgid>`). If delivery itself fails
#     (kill exits non-zero) while the group is still alive, prints a loud
#     diagnostic naming the PGID and stays attached — never returns while the
#     group is live, never falls back to killing a single process. A later
#     INT/TERM retries group delivery.
#   - Re-`wait`s until the child has actually exited: Bash (esp. 3.2 on
#     Darwin) can return from a signal-interrupted `wait` with rc=128+N while
#     the child's own delayed-teardown trap is still running — returning at
#     that point would recreate the exact orphan defect this helper exists
#     to fix.
#   - Second interrupt while still tearing down: forwarded immediately, same
#     as the first — no special-case hard-halt here (the BEAM's own
#     BuildSignalHandler owns the "second signal -> hard halt" semantics;
#     this helper's job ends at reliable signal delivery + wait).
#   - Restores prior trap/job-control state before returning.
set -uo pipefail

# _lsb_child_pid / _lsb_child_registered / _lsb_got_signal are module-scope
# (not `local` to run_supervised_loop) so the trap handler — which fires as
# an independent execution context, not a nested call inside the function
# body — can read/update them for the function's own post-wait logic to see.
_lsb_child_pid=""
_lsb_child_registered=0
_lsb_got_signal=0

# _lsb_forward — trap body. Forwards SIGTERM to the child's process group
# (child_pid == pgid, guaranteed by `set -m` before spawn). No-ops loudly
# (never fatally) when there is no child yet, the child already exited, or
# delivery itself fails — the caller decides what "no delivery" means.
_lsb_forward() {
    _lsb_got_signal=1
    if [[ "$_lsb_child_registered" -eq 0 ]]; then
        # Signal arrived before the child was ever spawned — nothing to
        # forward to. run_supervised_loop's own pre-spawn check handles the
        # 130 return in this case.
        return 0
    fi
    if ! kill -0 "$_lsb_child_pid" 2>/dev/null; then
        # Child (whole group) already gone — a harmless race, not a
        # delivery failure.
        return 0
    fi
    if ! kill -TERM -"$_lsb_child_pid" 2>/dev/null; then
        printf 'loop-signal-bridge: failed to deliver group SIGTERM to pgid %s — will retry on next signal\n' "$_lsb_child_pid" >&2
    fi
}

# run_supervised_loop <cmd...>
# Spawns "$@" as a job-controlled child, trapping INT/TERM to forward a
# group SIGTERM, re-waiting until the child truly exits. Returns the child's
# terminal wait status (or 130 if a signal arrived before spawn).
run_supervised_loop() {
    if [[ $# -eq 0 ]]; then
        echo "loop-signal-bridge: run_supervised_loop called with no command" >&2
        return 2
    fi

    # Snapshot prior job-control state so we can restore it — `set -m` is a
    # shell-wide toggle, not scoped to this function.
    local _prior_monitor="+m"
    case "$-" in
    *m*) _prior_monitor="-m" ;;
    esac
    set -m

    _lsb_child_pid=""
    _lsb_child_registered=0
    _lsb_got_signal=0
    trap '_lsb_forward' INT TERM

    if [[ "$_lsb_got_signal" -eq 1 ]]; then
        # Signal already landed while we were setting up (vanishingly
        # unlikely, but cheap to guard) — same as pre-spawn-signal below.
        trap - INT TERM
        [[ "$_prior_monitor" == "-m" ]] && set -m || set +m
        return 130
    fi

    "$@" </dev/null &
    _lsb_child_pid=$!
    _lsb_child_registered=1

    if [[ "$_lsb_got_signal" -eq 1 ]]; then
        # Race: a signal landed between trap install and spawn completing.
        # The trap already tried to forward (child_registered flips to 1
        # only after this line, so that attempt no-op'd) — forward now that
        # the child is registered, then fall through to the normal wait loop
        # so teardown is still observed rather than abandoned.
        _lsb_forward
    fi

    local rc=0
    while :; do
        wait "$_lsb_child_pid"
        rc=$?
        if [[ "$_lsb_got_signal" -eq 1 ]] && kill -0 "$_lsb_child_pid" 2>/dev/null; then
            # Interrupted wait: bash returned (often 128+signal) but the
            # child's own delayed-teardown trap is still running. Re-wait
            # rather than returning — returning here is exactly the orphan
            # defect this helper exists to prevent.
            _lsb_got_signal=0
            continue
        fi
        break
    done

    trap - INT TERM
    if [[ "$_prior_monitor" == "-m" ]]; then
        set -m
    else
        set +m
    fi

    return "$rc"
}
