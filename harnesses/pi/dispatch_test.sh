#!/usr/bin/env bash
# dispatch_test.sh — hermetic unit tests for harnesses/pi/dispatch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
DISPATCH="$SCRIPT_DIR/dispatch.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if grep -Fq -- "$needle" <<<"$haystack" 2>/dev/null; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:400}"
        fail=$((fail + 1))
    fi
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if grep -Fq -- "$needle" <<<"$haystack" 2>/dev/null; then
        printf 'FAIL: %s — unexpected match for %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:400}"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"

# Fake mix stub — dispatch.sh always execs `mix codegen.loop`. Stub it so
# these hermetic tests never invoke a real LLM/ExUnit round-trip; capture
# argv + env for assertions.
cat >"$FAKE_BIN/mix" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${TARGET_MIX_ARGS_FILE:-/dev/null}"
env >> "${TARGET_MIX_ARGS_FILE:-/dev/null}"
exit 0
STUB
chmod +x "$FAKE_BIN/mix"

# Passing codegen-log stub — dispatch.sh preflights `codegen-log --version`
# before spawning any role. Without this stub, every exec-path case below
# would break (codegen-log absent from PATH -> preflight abort).
printf '#!/usr/bin/env bash\nprintf "codegen-log root=resolved\\n"\nexit 0\n' >"$FAKE_BIN/codegen-log"
chmod +x "$FAKE_BIN/codegen-log"

make_temp_dispatch() {
    local root="$1"
    mkdir -p "$root"
    cp "$DISPATCH" "$root/dispatch.sh"
    chmod +x "$root/dispatch.sh"
}

# ── Test 1: loop execs mix codegen.loop ───────────────────────────────────────
TEST1_HARNESS="$TMP_ROOT/harnesses/pi"
make_temp_dispatch "$TEST1_HARNESS"
mkdir -p "$TMP_ROOT/project"

MIX_ARGS_FILE_1="$TMP_ROOT/mix-args-1.txt"
rc=0
TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_1" \
    PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_STACK=phoenix \
    CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
    "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
    >/dev/null 2>&1 || rc=$?

assert_eq "loop path: exit 0 (mix stub)" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE_1" ]]; then
    MIX_ARGS_CONTENT="$(cat "$MIX_ARGS_FILE_1")"
    assert_contains "loop path: mix codegen.loop invoked" "$MIX_ARGS_CONTENT" "codegen.loop"
    assert_contains "loop path: --harness=pi passed" "$MIX_ARGS_CONTENT" "--harness=pi"
    assert_contains "loop path: --stack passed" "$MIX_ARGS_CONTENT" "--stack="
    assert_contains "loop path: --cwd passed" "$MIX_ARGS_CONTENT" "$TMP_ROOT/project"
    assert_contains "loop path: prompt forwarded" "$MIX_ARGS_CONTENT" "hello prompt"
else
    printf 'FAIL: loop path — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 2: missing test_harness/ dir → exit 2 (fail loud, no silent fallback) ──
TEST2_HARNESS="$TMP_ROOT/no-loop-dir/harnesses/pi"
make_temp_dispatch "$TEST2_HARNESS"
FAKE_CODEGEN_NO_LOOP="$TMP_ROOT/fake-codegen-no-loop"
mkdir -p "$FAKE_CODEGEN_NO_LOOP/harnesses/pi"
cp "$TEST2_HARNESS/dispatch.sh" "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/dispatch.sh"
mkdir -p "$TMP_ROOT/no-loop-dir/project"

rc=0
out=$(
    PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_NO_LOOP" \
        CODEGEN_BUILD_STACK=phoenix \
        CODEGEN_BUILD_CWD="$TMP_ROOT/no-loop-dir/project" \
        "$FAKE_CODEGEN_NO_LOOP/harnesses/pi/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "missing test_harness/ dir: exit code 2" "2" "$rc"
assert_contains "missing test_harness/ dir: stderr mentions 'orchestration loop dir not found'" \
    "$out" "orchestration loop dir not found"

# ── Test 3: env-isolation — provider keys stripped before exec (loop path) ────
# env -u strips ambient CODEGEN_CALL_* vars: when this test itself runs inside
# a codegen-call-launched session (e.g. a developer role invocation), the
# parent process's own CODEGEN_CALL_PROMPT/etc. would otherwise leak into the
# child env dump and produce false-positive substring matches unrelated to
# the actual OPENAI_API_KEY/ANTHROPIC_API_KEY/CURSOR_API_KEY leak this test
# targets.
MIX_ARGS_FILE_3="$TMP_ROOT/mix-args-3.txt"
rc=0
env \
    -u CODEGEN_CALL_PROMPT \
    -u CODEGEN_CALL_AGENT \
    -u CODEGEN_CALL_MODEL \
    -u CODEGEN_CALL_EFFORT \
    -u CODEGEN_CALL_RESUME \
    -u CODEGEN_CALL_SYSTEM_PROMPT \
    -u CODEGEN_CALL_HARNESS \
    -u CODEGEN_CALL_JSON_SCHEMA \
    -u CODEGEN_CALL_JSON_SCHEMA_PATH \
    -u CODEGEN_CALL_ALLOWED_TOOLS \
    -u CODEGEN_CALL_ALLOWED_TOOLS_SET \
    -u CODEGEN_CALL_SETTINGS_PATH \
    -u CODEGEN_CALL_EXTENSION_PATH \
    -u CODEGEN_CALL_TRANSCRIPT_PATH \
    TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_3" \
    PATH="$FAKE_BIN:$PATH" \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
    CODEGEN_BUILD_STACK=phoenix \
    CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
    OPENAI_API_KEY=leak1 \
    ANTHROPIC_API_KEY=leak2 \
    CURSOR_API_KEY=leak3 \
    "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
    >/dev/null 2>&1 || rc=$?

assert_eq "env-isolation: loop path exit 0" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE_3" ]]; then
    ENV_OUT="$(cat "$MIX_ARGS_FILE_3")"
    assert_not_contains "env-isolation: OPENAI_API_KEY not in loop exec env" "$ENV_OUT" "OPENAI_API_KEY"
    assert_not_contains "env-isolation: ANTHROPIC_API_KEY not in loop exec env" "$ENV_OUT" "ANTHROPIC_API_KEY"
    assert_not_contains "env-isolation: CURSOR_API_KEY not in loop exec env" "$ENV_OUT" "CURSOR_API_KEY"
else
    printf 'FAIL: env-isolation — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 4: CODEGEN_BUILD_STACK unset/empty → exit 2 ──────────────────────────
# Regression lock: dispatch.sh must NOT silently coerce an empty/unset stack
# to "phoenix" — it must fail loud naming CODEGEN_BUILD_STACK.
# env -i (not just omitting the var) — guarantees CODEGEN_BUILD_STACK is truly
# absent regardless of the CALLER's ambient environment (a prior make-test
# fixture or manual export in the same shell can otherwise leak it through).
MIX_ARGS_FILE_4="$TMP_ROOT/mix-args-4.txt"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_4" \
        PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
        "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "missing CODEGEN_BUILD_STACK: exit code 2" "2" "$rc"
assert_contains "missing CODEGEN_BUILD_STACK: stderr names CODEGEN_BUILD_STACK" \
    "$out" "CODEGEN_BUILD_STACK is required but empty/unset"
if [[ -f "$MIX_ARGS_FILE_4" ]]; then
    printf 'FAIL: missing CODEGEN_BUILD_STACK — mix must NOT have been invoked\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# ── Test 5: codegen-log preflight — broken/absent codegen-log aborts loud,
# before any role spawns (assert exec-not-reached via the mix-args-file
# shimmed-subprocess marker, same pattern used by Test 4). ─────────────────
FAKE_BIN_BROKEN_LOG="$TMP_ROOT/bin-broken-log"
mkdir -p "$FAKE_BIN_BROKEN_LOG"
cp "$FAKE_BIN/mix" "$FAKE_BIN_BROKEN_LOG/mix"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN_BROKEN_LOG/codegen-log"
chmod +x "$FAKE_BIN_BROKEN_LOG/codegen-log"

MIX_ARGS_FILE_5="$TMP_ROOT/mix-args-5.txt"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        TARGET_MIX_ARGS_FILE="$MIX_ARGS_FILE_5" \
        PATH="$FAKE_BIN_BROKEN_LOG:$PATH" \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" \
        CODEGEN_BUILD_STACK=phoenix \
        CODEGEN_BUILD_CWD="$TMP_ROOT/project" \
        "$TEST1_HARNESS/dispatch.sh" "hello prompt" \
        2>&1
) || rc=$?
assert_eq "broken codegen-log: exit code non-zero (2)" "2" "$rc"
assert_contains "broken codegen-log: stderr names codegen-log unresolvable" "$out" "codegen-log unresolvable"
assert_contains "broken codegen-log: stderr suggests make install" "$out" "make install"
if [[ -f "$MIX_ARGS_FILE_5" ]]; then
    printf 'FAIL: broken codegen-log — mix must NOT have been invoked (preflight must abort before exec)\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# ── Test 6: loop child non-zero exit → exit code propagates verbatim, and a
# codegen-log exit record is written IFF the loop inited its own log (.active
# changed during the spawn). dispatch.sh resolves codegen-log by
# $CODEGEN_DIR/codegen-log (never $PATH), so the stub must live under the
# fake OCG_CODEGEN_DIR root, not just FAKE_BIN.
FAKE_CODEGEN_EXITREC="$TMP_ROOT/fake-codegen-exitrec"
mkdir -p "$FAKE_CODEGEN_EXITREC/harnesses/pi" "$FAKE_CODEGEN_EXITREC/harnesses/shared" "$FAKE_CODEGEN_EXITREC/test_harness"
cp "$DISPATCH" "$FAKE_CODEGEN_EXITREC/harnesses/pi/dispatch.sh"
chmod +x "$FAKE_CODEGEN_EXITREC/harnesses/pi/dispatch.sh"
# dispatch.sh sources loop-signal-bridge.sh from $CODEGEN_DIR/harnesses/shared/
cp "$CODEGEN_ROOT/harnesses/shared/loop-signal-bridge.sh" "$FAKE_CODEGEN_EXITREC/harnesses/shared/loop-signal-bridge.sh"

EXITREC_CWD="$TMP_ROOT/exitrec-cwd"
mkdir -p "$EXITREC_CWD/codegen/logging"
CODEGEN_LOG_ARGS_FILE="$TMP_ROOT/codegen-log-args.txt"

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

FAKE_BIN_EXITREC="$TMP_ROOT/bin-exitrec"
mkdir -p "$FAKE_BIN_EXITREC"
cp "$FAKE_CODEGEN_EXITREC/codegen-log" "$FAKE_BIN_EXITREC/codegen-log"
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
        "$FAKE_CODEGEN_EXITREC/harnesses/pi/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "loop child non-zero exit: dispatch.sh propagates it verbatim" "1" "$rc"
if [[ -f "$CODEGEN_LOG_ARGS_FILE" ]]; then
    CODEGEN_LOG_ARGS="$(cat "$CODEGEN_LOG_ARGS_FILE")"
    assert_contains "exit record: codegen-log exit invoked" "$CODEGEN_LOG_ARGS" "exit --status 1"
else
    printf 'FAIL: exit record — codegen-log exit was never invoked\n'
    fail=$((fail + 1))
fi

# ── Test 7: loop dies before ever creating a log (.active unchanged) — no
# exit record is written; dispatch.sh notes it on stderr instead. ───────────
rm -f "$CODEGEN_LOG_ARGS_FILE"
rm -f "$EXITREC_CWD/codegen/logging/.active"
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
        "$FAKE_CODEGEN_EXITREC/harnesses/pi/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "no-log death: dispatch.sh propagates the loop's exit code" "1" "$rc"
assert_contains "no-log death: stderr notes the record was skipped" \
    "$out" "before a cycle log existed"
if [[ -f "$CODEGEN_LOG_ARGS_FILE" ]]; then
    printf 'FAIL: no-log death — codegen-log exit must NOT have been invoked\n'
    fail=$((fail + 1))
else
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

TEST8_HARNESS="$TMP_ROOT/harness-pty/harnesses/pi"
make_temp_dispatch "$TEST8_HARNESS"
mkdir -p "$TMP_ROOT/harness-pty/test_harness" "$TMP_ROOT/harness-pty/harnesses/shared"
cp "$CODEGEN_ROOT/harnesses/shared/loop-signal-bridge.sh" "$TMP_ROOT/harness-pty/harnesses/shared/loop-signal-bridge.sh"

PTY_OUT_FILE="$TMP_ROOT/pty-out.txt"
PTY_RC_FILE="$TMP_ROOT/pty-rc.txt"
rm -f "$PTY_OUT_FILE" "$PTY_RC_FILE"

python3 - "$TEST8_HARNESS/dispatch.sh" "$FAKE_BIN_PTY" "$TMP_ROOT/harness-pty" "$PTY_OUT_FILE" "$PTY_RC_FILE" <<'PYEOF'
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
    assert_contains "pty: loop stub actually ran" "$PTY_OUT" "pty-mix-ran"
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
mkdir -p "$FAKE_CODEGEN_STREAMS/test_harness" "$FAKE_CODEGEN_STREAMS/harnesses/shared"
cp "$CODEGEN_ROOT/harnesses/shared/loop-signal-bridge.sh" "$FAKE_CODEGEN_STREAMS/harnesses/shared/loop-signal-bridge.sh"
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
    "$TEST1_HARNESS/dispatch.sh" "dummy-prompt" \
    >"$STREAMS_STDOUT" 2>"$STREAMS_STDERR" || rc=$?
assert_eq "stderr capture: loop status preserved" "7" "$rc"
STREAMS_STDOUT_CONTENT="$(cat "$STREAMS_STDOUT")"
STREAMS_STDERR_CONTENT="$(cat "$STREAMS_STDERR")"
assert_contains "stderr capture: stdout remains byte-transparent" \
    "$STREAMS_STDOUT_CONTENT" "stream-json-stdout"
assert_contains "stderr capture: loop stderr is still emitted" \
    "$STREAMS_STDERR_CONTENT" "loop-stderr-line"
assert_not_contains "stderr capture: stdout is not mirrored to stderr" \
    "$STREAMS_STDERR_CONTENT" "stream-json-stdout"

DISPATCH_SOURCE="$(cat "$DISPATCH")"
assert_not_contains "stderr capture avoids restricted /dev/fd process substitution" \
    "$DISPATCH_SOURCE" '"${_loop_argv[@]}" 2> >(tee'
assert_contains "stderr capture uses portable named FIFO" \
    "$DISPATCH_SOURCE" 'mkfifo "$_stderr_fifo"'
assert_contains "stderr capture preserves loop status explicitly" \
    "$DISPATCH_SOURCE" 'exit "$_status"'

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
