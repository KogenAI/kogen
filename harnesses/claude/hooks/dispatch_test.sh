#!/usr/bin/env bash
# dispatch_test.sh — hermetic unit tests for harnesses/claude/dispatch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/../dispatch.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle:   %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack:  %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# ── Shared temp dir — cleaned on EXIT ────────────────────────────────────────
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Passing codegen-log stub — dispatch.sh preflights `codegen-log --version`
# before spawning any role. Without this stub, every exec-path case below
# would break (codegen-log absent from PATH -> preflight abort).
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nprintf "codegen-log root=resolved\\n"\nexit 0\n' >"$FAKE_BIN/codegen-log"
chmod +x "$FAKE_BIN/codegen-log"

FAKE_HARNESS="$TMP_ROOT/harness"
mkdir -p "$FAKE_HARNESS"
# Copy dispatch.sh into the fake harness dir so SCRIPT_DIR resolves correctly
cp "$DISPATCH" "$FAKE_HARNESS/dispatch.sh"
chmod +x "$FAKE_HARNESS/dispatch.sh"

FAKE_CODEGEN="$TMP_ROOT/codegen"
mkdir -p "$FAKE_CODEGEN"

# ── Test 1: no test_harness/ dir → exit 2 + "orchestration loop dir not found" ──
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_STACK=phoenix \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "missing test_harness/ dir: exit code 2" "2" "$rc"
assert_contains "missing test_harness/ dir: stderr mentions 'orchestration loop dir not found'" \
    "orchestration loop dir not found" "$out"

# ── Test 2: valid fake mix + test_harness/ dir → loop execs ─────────────────
FAKE_BIN_MIX="$TMP_ROOT/bin-mix"
mkdir -p "$FAKE_BIN_MIX"
cp "$FAKE_BIN/codegen-log" "$FAKE_BIN_MIX/codegen-log"
MIX_ARGS_FILE="$TMP_ROOT/mix-args.txt"
cat >"$FAKE_BIN_MIX/mix" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$MIX_ARGS_FILE"
env >>"$MIX_ARGS_FILE"
exit 0
STUB
chmod +x "$FAKE_BIN_MIX/mix"
mkdir -p "$FAKE_CODEGEN/test_harness"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_STACK=phoenix \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "loop path: exit 0 (mix stub)" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    MIX_ARGS_CONTENT="$(cat "$MIX_ARGS_FILE")"
    assert_contains "loop path: mix codegen.loop invoked" "codegen.loop" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: --harness=claude_code passed" "--harness=claude_code" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: --stack passed" "--stack=" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: --cwd passed" "--cwd=" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: prompt forwarded" "dummy-prompt" "$MIX_ARGS_CONTENT"
else
    printf 'FAIL: loop path — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 3: env-isolation — provider keys stripped before exec (loop path) ────
rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_STACK=phoenix \
        OPENAI_API_KEY=leak1 \
        ANTHROPIC_API_KEY=leak2 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "env-isolation: loop path exit 0" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    ENV_OUT="$(cat "$MIX_ARGS_FILE")"
    assert_not_contains "env-isolation: OPENAI_API_KEY not in loop exec env" \
        "OPENAI_API_KEY" "$ENV_OUT"
    assert_not_contains "env-isolation: ANTHROPIC_API_KEY not in loop exec env" \
        "ANTHROPIC_API_KEY" "$ENV_OUT"
    assert_contains "env-isolation: CODEGEN_DIR present (positive control — mix stub ran)" \
        "CODEGEN_DIR=" "$ENV_OUT"
else
    printf 'FAIL: env-isolation — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 4: CODEGEN_BUILD_STACK unset/empty → exit 2 + clear message ────────
# Regression lock: dispatch.sh must NOT silently coerce an empty/unset stack
# to "phoenix" — it must fail loud naming CODEGEN_BUILD_STACK.
rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "missing CODEGEN_BUILD_STACK: exit code 2" "2" "$rc"
assert_contains "missing CODEGEN_BUILD_STACK: stderr names CODEGEN_BUILD_STACK" \
    "CODEGEN_BUILD_STACK is required but empty/unset" "$out"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    printf 'FAIL: missing CODEGEN_BUILD_STACK — mix must NOT have been invoked\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: missing CODEGEN_BUILD_STACK — mix not invoked\n'
    pass=$((pass + 1))
fi

# ── Test 5: codegen-log preflight — broken/absent codegen-log aborts loud,
# before any role spawns (assert exec-not-reached via the mix-args-file
# shimmed-subprocess marker). ────────────────────────────────────────────────
FAKE_BIN_BROKEN_LOG="$TMP_ROOT/bin-broken-log"
mkdir -p "$FAKE_BIN_BROKEN_LOG"
cp "$FAKE_BIN_MIX/mix" "$FAKE_BIN_BROKEN_LOG/mix"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN_BROKEN_LOG/codegen-log"
chmod +x "$FAKE_BIN_BROKEN_LOG/codegen-log"

rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_BROKEN_LOG:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_STACK=phoenix \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "broken codegen-log: exit code non-zero (2)" "2" "$rc"
assert_contains "broken codegen-log: stderr names codegen-log unresolvable" \
    "codegen-log unresolvable" "$out"
assert_contains "broken codegen-log: stderr suggests make install" \
    "make install" "$out"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    printf 'FAIL: broken codegen-log — mix must NOT have been invoked (preflight must abort before exec)\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: broken codegen-log — mix not invoked (aborted before exec)\n'
    pass=$((pass + 1))
fi

# ── Test 6: loop child non-zero exit → exit code propagates verbatim, and a
# codegen-log exit record is written IFF the loop inited its own log (.active
# changed during the spawn). ──────────────────────────────────────────────────
FAKE_BIN_EXITREC="$TMP_ROOT/bin-exitrec"
mkdir -p "$FAKE_BIN_EXITREC"
EXITREC_CWD="$TMP_ROOT/exitrec-cwd"
mkdir -p "$EXITREC_CWD/codegen/logging"
CODEGEN_LOG_ARGS_FILE="$TMP_ROOT/codegen-log-args.txt"
FAKE_CODEGEN_EXITREC="$TMP_ROOT/codegen-exitrec"
mkdir -p "$FAKE_CODEGEN_EXITREC/test_harness"
# The real codegen-log binary lives at $CODEGEN_DIR/codegen-log (derived from
# OCG_CODEGEN_DIR here) — dispatch.sh resolves it by that path, NEVER $PATH.
cat >"$FAKE_CODEGEN_EXITREC/codegen-log" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
    printf 'codegen-log root=resolved\n'
    exit 0
fi
printf '%s\n' "$*" >>"$CODEGEN_LOG_ARGS_FILE"
exit 0
STUB
chmod +x "$FAKE_CODEGEN_EXITREC/codegen-log"
# PATH-visible codegen-log too (preflight check uses bare `codegen-log`).
cp "$FAKE_CODEGEN_EXITREC/codegen-log" "$FAKE_BIN_EXITREC/codegen-log"
# mix stub: writes .active (simulating the loop's own `codegen-log init`),
# then exits non-zero — the death class this record exists to catch.
cat >"$FAKE_BIN_EXITREC/mix" <<STUB
#!/usr/bin/env bash
printf '%s' "$EXITREC_CWD/codegen/logging/20260101_000000_exitrec_cycle.jsonl" >"$EXITREC_CWD/codegen/logging/.active"
echo "simulated loop stacktrace" >&2
exit 1
STUB
chmod +x "$FAKE_BIN_EXITREC/mix"

rm -f "$CODEGEN_LOG_ARGS_FILE"
rc=0
out=$(
    CODEGEN_LOG_ARGS_FILE="$CODEGEN_LOG_ARGS_FILE" \
        env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_EXITREC:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_EXITREC" \
        CODEGEN_BUILD_STACK=phoenix \
        CODEGEN_BUILD_CWD="$EXITREC_CWD" \
        CODEGEN_LOG_ARGS_FILE="$CODEGEN_LOG_ARGS_FILE" \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "loop child non-zero exit: dispatch.sh propagates it verbatim" "1" "$rc"
if [[ -f "$CODEGEN_LOG_ARGS_FILE" ]]; then
    CODEGEN_LOG_ARGS="$(cat "$CODEGEN_LOG_ARGS_FILE")"
    assert_contains "exit record: codegen-log exit invoked" "exit --status 1" "$CODEGEN_LOG_ARGS"
else
    printf 'FAIL: exit record — codegen-log exit was never invoked\n'
    fail=$((fail + 1))
fi

# ── Test 7: loop dies before ever creating a log (.active unchanged) — no
# exit record is written; dispatch.sh notes it on stderr instead. ───────────
rm -f "$CODEGEN_LOG_ARGS_FILE"
rm -rf "$EXITREC_CWD/codegen/logging/.active"
FAKE_BIN_NOLOG="$TMP_ROOT/bin-nolog"
mkdir -p "$FAKE_BIN_NOLOG"
cp "$FAKE_CODEGEN_EXITREC/codegen-log" "$FAKE_BIN_NOLOG/codegen-log"
cat >"$FAKE_BIN_NOLOG/mix" <<STUB
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$FAKE_BIN_NOLOG/mix"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_NOLOG:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_EXITREC" \
        CODEGEN_BUILD_STACK=phoenix \
        CODEGEN_BUILD_CWD="$EXITREC_CWD" \
        CODEGEN_LOG_ARGS_FILE="$CODEGEN_LOG_ARGS_FILE" \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "no-log death: dispatch.sh propagates the loop's exit code" "1" "$rc"
assert_contains "no-log death: stderr notes the record was skipped" \
    "before a cycle log existed" "$out"
if [[ -f "$CODEGEN_LOG_ARGS_FILE" ]]; then
    printf 'FAIL: no-log death — codegen-log exit must NOT have been invoked\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: no-log death — codegen-log exit not invoked\n'
    pass=$((pass + 1))
fi

# ── Test 8: dispatch.sh under a real pty must NOT stop on SIGTTIN — the
# backgrounded loop spawn (`set -m` + `&`) must not inherit the terminal on
# stdin. Regression for the "finished build never returns the prompt" defect:
# a background process group that reads the tty gets SIGTTIN and stops (T)
# forever. The fix is `</dev/null` on the spawn; reverting it makes this
# hang until the deadline kills it, turning the hang into a FAIL.
FAKE_BIN_PTY="$TMP_ROOT/bin-pty"
mkdir -p "$FAKE_BIN_PTY"
cp "$FAKE_BIN/codegen-log" "$FAKE_BIN_PTY/codegen-log"
cat >"$FAKE_BIN_PTY/mix" <<'STUB'
#!/usr/bin/env bash
# Real mix codegen.loop never reads stdin — this stub matches that contract
# so the test proves the pgroup doesn't inherit/need the tty at all.
printf 'pty-mix-ran\n'
exit 0
STUB
chmod +x "$FAKE_BIN_PTY/mix"

FAKE_CODEGEN_PTY="$TMP_ROOT/codegen-pty"
mkdir -p "$FAKE_CODEGEN_PTY/test_harness"
FAKE_HARNESS_PTY="$TMP_ROOT/harness-pty"
mkdir -p "$FAKE_HARNESS_PTY"
cp "$DISPATCH" "$FAKE_HARNESS_PTY/dispatch.sh"
chmod +x "$FAKE_HARNESS_PTY/dispatch.sh"

PTY_OUT_FILE="$TMP_ROOT/pty-out.txt"
PTY_RC_FILE="$TMP_ROOT/pty-rc.txt"
rm -f "$PTY_OUT_FILE" "$PTY_RC_FILE"

python3 - "$FAKE_HARNESS_PTY/dispatch.sh" "$FAKE_BIN_PTY" "$FAKE_CODEGEN_PTY" "$PTY_OUT_FILE" "$PTY_RC_FILE" <<'PYEOF'
import os
import pty
import select
import signal
import sys
import time

dispatch, fake_bin, fake_codegen, out_file, rc_file = sys.argv[1:6]

env = dict(os.environ)
env["PATH"] = fake_bin + ":" + env.get("PATH", "")
env["OCG_CODEGEN_DIR"] = fake_codegen
env["CODEGEN_BUILD_STACK"] = "phoenix"

pid, master_fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", dispatch, "dummy-prompt"], env)
    os._exit(127)

deadline = time.time() + 15
buf = b""
while time.time() < deadline:
    remaining = deadline - time.time()
    if remaining <= 0:
        break
    # Bound the read itself, not just the loop re-entry — a stopped
    # (SIGTTIN) child writes nothing, so a bare os.read would block past
    # the deadline. select() enforces the timeout on the blocking read.
    readable, _, _ = select.select([master_fd], [], [], remaining)
    if not readable:
        continue
    try:
        chunk = os.read(master_fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid, status = pid, 0
    if done_pid == pid:
        break
else:
    # Deadline hit — the exact hang this test guards against.
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    with open(out_file, "wb") as f:
        f.write(buf)
    with open(rc_file, "w") as f:
        f.write("TIMEOUT")
    sys.exit(0)

try:
    done_pid, status = os.waitpid(pid, 0)
except ChildProcessError:
    status = 0

with open(out_file, "wb") as f:
    f.write(buf)
with open(rc_file, "w") as f:
    if os.WIFEXITED(status):
        f.write(str(os.WEXITSTATUS(status)))
    else:
        f.write("SIGNALED")
PYEOF

PTY_RC="$(cat "$PTY_RC_FILE" 2>/dev/null || echo "MISSING")"
assert_eq "pty: dispatch.sh returns (not stuck on SIGTTIN)" "0" "$PTY_RC"
if [[ -f "$PTY_OUT_FILE" ]]; then
    PTY_OUT="$(cat "$PTY_OUT_FILE")"
    assert_contains "pty: loop stub actually ran" "pty-mix-ran" "$PTY_OUT"
fi

# ── Test 9: stderr capture must not corrupt loop stdout ─────────────────────
FAKE_BIN_STREAMS="$TMP_ROOT/bin-streams"
mkdir -p "$FAKE_BIN_STREAMS"
cp "$FAKE_BIN/codegen-log" "$FAKE_BIN_STREAMS/codegen-log"
cat >"$FAKE_BIN_STREAMS/mix" <<'STUB'
#!/usr/bin/env bash
printf 'stream-json-stdout\n'
printf 'loop-stderr-line\n' >&2
exit 7
STUB
chmod +x "$FAKE_BIN_STREAMS/mix"

FAKE_CODEGEN_STREAMS="$TMP_ROOT/codegen-streams"
mkdir -p "$FAKE_CODEGEN_STREAMS/test_harness"
STREAMS_CWD="$TMP_ROOT/streams-cwd"
mkdir -p "$STREAMS_CWD/codegen/logging"
STREAMS_STDOUT="$TMP_ROOT/streams-stdout.txt"
STREAMS_STDERR="$TMP_ROOT/streams-stderr.txt"
rc=0
env -i \
    HOME="${HOME:-/tmp}" \
    PATH="$FAKE_BIN_STREAMS:$PATH" \
    OCG_CODEGEN_DIR="$FAKE_CODEGEN_STREAMS" \
    CODEGEN_BUILD_STACK=phoenix \
    CODEGEN_BUILD_CWD="$STREAMS_CWD" \
    bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
    >"$STREAMS_STDOUT" 2>"$STREAMS_STDERR" || rc=$?
assert_eq "stderr capture: loop status preserved" "7" "$rc"
STREAMS_STDOUT_CONTENT="$(cat "$STREAMS_STDOUT")"
STREAMS_STDERR_CONTENT="$(cat "$STREAMS_STDERR")"
assert_contains "stderr capture: stdout remains byte-transparent" \
    "stream-json-stdout" "$STREAMS_STDOUT_CONTENT"
assert_contains "stderr capture: loop stderr is still emitted" \
    "loop-stderr-line" "$STREAMS_STDERR_CONTENT"
assert_not_contains "stderr capture: stdout is not mirrored to stderr" \
    "stream-json-stdout" "$STREAMS_STDERR_CONTENT"

DISPATCH_SOURCE="$(cat "$DISPATCH")"
assert_not_contains "stderr capture avoids restricted /dev/fd process substitution" \
    '"${_loop_argv[@]}" 2> >(tee' "$DISPATCH_SOURCE"
assert_contains "stderr capture uses portable named FIFO" \
    'mkfifo "$_stderr_fifo"' "$DISPATCH_SOURCE"
assert_contains "stderr capture preserves loop status explicitly" \
    'exit "$_status"' "$DISPATCH_SOURCE"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
