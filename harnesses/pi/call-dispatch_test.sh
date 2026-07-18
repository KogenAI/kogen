#!/usr/bin/env bash
# call-dispatch_test.sh — hermetic unit tests for harnesses/pi/call-dispatch.sh
#
# Uses a PATH-override stub `pi` so no real model call is made and no token
# budget is spent.
#
# Regression focus: pi is spawned with `2>&1`, so any pi stderr chatter
# (cold-session warning, model-catalog fetch, deprecation notice) is
# interleaved into the same capture file as the JSONL stream. The parser MUST
# skip undecodable lines rather than abort. Before the `-R 'fromjson?'` fix a
# SINGLE stderr line made every successful call report
# `no agent_end event found in pi JSONL` — jq hard-aborts at the first
# non-JSON line and emits nothing at all.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/call-dispatch.sh"

pass=0
fail=0

assert_jq() {
    local desc="$1" json="$2" filter="$3" expected="$4" actual
    actual="$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n  envelope: %s\n' \
            "$desc" "$expected" "$actual" "${json:0:400}"
        fail=$((fail + 1))
    fi
}

BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

# ── Stub pi: emit $STUB_STDERR on stderr, then $FIXTURE_PATH on stdout ───────
STUB_DIR="$BASE_TMP/stub_bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/pi" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub pi: ignore all args. Emit optional stderr noise, then the JSONL fixture.
if [[ -n "${STUB_STDERR:-}" ]]; then
    printf '%s\n' "$STUB_STDERR" >&2
fi
cat "$FIXTURE_PATH"
exit "${STUB_EXIT:-0}"
STUB_EOF
chmod +x "$STUB_DIR/pi"
export PATH="$STUB_DIR:$PATH"

# ── Fixtures ──────────────────────────────────────────────────────────────────
FIXTURE_OK="$BASE_TMP/agent_end.jsonl"
cat >"$FIXTURE_OK" <<'EOF'
{"type":"tool_execution_end","toolName":"read"}
{"type":"tool_execution_end","toolName":"read"}
{"type":"tool_execution_end","toolName":"edit"}
{"type":"agent_end","messages":[{"role":"assistant","content":"the answer is 4"}],"usage":{"input_tokens":120,"output_tokens":18,"cost_usd":0.002},"num_turns":3}
EOF

FIXTURE_NO_END="$BASE_TMP/no_agent_end.jsonl"
cat >"$FIXTURE_NO_END" <<'EOF'
{"type":"tool_execution_end","toolName":"read"}
EOF

# ── Required env ──────────────────────────────────────────────────────────────
export CODEGEN_CALL_SYSTEM_PROMPT="You are a test assistant."
export CODEGEN_CALL_MODEL="openai-codex/gpt-5.6-terra"
export CODEGEN_CALL_EFFORT="medium"
export CODEGEN_CALL_PROMPT="What is 2+2?"
unset CODEGEN_CALL_JSON_SCHEMA CODEGEN_CALL_AGENT CODEGEN_CALL_ALLOWED_TOOLS_SET 2>/dev/null || true
unset CODEGEN_CALL_ALLOWED_TOOLS CODEGEN_CALL_RESUME CODEGEN_CALL_SESSION_ID 2>/dev/null || true
unset CODEGEN_LOOP 2>/dev/null || true

run_dispatch() {
    local rc=0
    ENVELOPE="$(bash "$DISPATCH" 2>/dev/null)" || rc=$?
    EXIT_RC="$rc"
}

# ── Case 1: clean stdout, no stderr noise (baseline — passed pre-fix too) ────
export FIXTURE_PATH="$FIXTURE_OK"
unset STUB_STDERR 2>/dev/null || true
run_dispatch
assert_jq "clean stream: status success" "$ENVELOPE" '.result.status' 'success'
assert_jq "clean stream: value carries reply" "$ENVELOPE" '.result.value' 'the answer is 4'
assert_jq "clean stream: input_tokens parsed" "$ENVELOPE" '.usage.input_tokens' '120'

# ── Case 2: THE REGRESSION — stderr noise interleaved before agent_end ───────
# Pre-fix this yielded {"status":"failed","reason":"no agent_end event found in
# pi JSONL"} despite a perfectly successful call.
export STUB_STDERR="warning: cold session — fetching model catalog"
run_dispatch
assert_jq "stderr noise: status STILL success" "$ENVELOPE" '.result.status' 'success'
assert_jq "stderr noise: reason is null" "$ENVELOPE" '.result.reason' 'null'
assert_jq "stderr noise: value survives" "$ENVELOPE" '.result.value' 'the answer is 4'
assert_jq "stderr noise: usage survives" "$ENVELOPE" '.usage.input_tokens' '120'
assert_jq "stderr noise: num_turns survives" "$ENVELOPE" '.usage.num_turns' '3'
assert_jq "stderr noise: tool metrics survive" "$ENVELOPE" '.metrics.read_count' '2'
assert_jq "stderr noise: read_edit_ratio survives" "$ENVELOPE" '.metrics.read_edit_ratio' '2'

# ── Case 3: multi-line + trailing stderr noise ───────────────────────────────
export STUB_STDERR="warning: line one
info: line two
deprecation: --mode json will change"
run_dispatch
assert_jq "multiline noise: status success" "$ENVELOPE" '.result.status' 'success'
assert_jq "multiline noise: value survives" "$ENVELOPE" '.result.value' 'the answer is 4'

# ── Case 4: noise must NOT manufacture a false success when call really failed ─
export FIXTURE_PATH="$FIXTURE_NO_END"
export STUB_STDERR="warning: cold session — fetching model catalog"
run_dispatch
assert_jq "genuinely no agent_end: status failed" "$ENVELOPE" '.result.status' 'failed'
assert_jq "genuinely no agent_end: honest reason" \
    "$ENVELOPE" '.result.reason' 'no agent_end event found in pi JSONL'
assert_jq "genuinely no agent_end: harness tagged" "$ENVELOPE" '.harness' 'pi'

# ── Case 5: errored turn — real errorMessage must reach result.reason ────────
# Captured verbatim from a live pi run against a decommissioned model id.
# pi emits agent_end with content: [] (indistinguishable from an empty reply),
# and puts the real cause in the assistant message's errorMessage.
FIXTURE_ERR="$BASE_TMP/agent_end_error.jsonl"
cat >"$FIXTURE_ERR" <<'EOF'
{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"reply ok"}]},{"role":"assistant","content":[],"stopReason":"error","errorMessage":"Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."}]}
EOF
export FIXTURE_PATH="$FIXTURE_ERR"
export STUB_STDERR="warning: cold session — fetching model catalog"
run_dispatch
assert_jq "errored turn: status failed" "$ENVELOPE" '.result.status' 'failed'
assert_jq "errored turn: real cause surfaces in reason" "$ENVELOPE" '.result.reason' \
    "Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."

# An empty reply with NO errorMessage keeps the generic wording.
FIXTURE_EMPTY="$BASE_TMP/agent_end_empty.jsonl"
cat >"$FIXTURE_EMPTY" <<'EOF'
{"type":"agent_end","messages":[{"role":"assistant","content":[]}]}
EOF
export FIXTURE_PATH="$FIXTURE_EMPTY"
run_dispatch
assert_jq "genuinely empty reply: generic reason retained" \
    "$ENVELOPE" '.result.reason' 'pi returned empty reply'

# ── Case 6: multi-line reply must survive intact (NO head -1 truncation) ─────
# Regression from a real pi static build: reviewer-static emitted a markdown
# table followed by the loop's required trailing sentinel. call-dispatch piped
# the extracted text through `head -1`, so the loop saw only
# "| Check | Verdict | Notes |", lost `REVIEW_VERDICT: APPROVED`, and failed
# the cycle with "reviewer output carried no parseable REVIEW_VERDICT:
# sentinel after 2 attempt(s)" — blaming the model for our truncation.
FIXTURE_MULTILINE="$BASE_TMP/agent_end_multiline.jsonl"
cat >"$FIXTURE_MULTILINE" <<'EOF'
{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"| Check | Verdict | Notes |\n|---|---|---|\n| Quality | OK | clean |\n\nREVIEW_VERDICT: APPROVED"}]}]}
EOF
export FIXTURE_PATH="$FIXTURE_MULTILINE"
export STUB_STDERR="warning: cold session — fetching model catalog"
run_dispatch
assert_jq "multi-line reply: status success" "$ENVELOPE" '.result.status' 'success'
assert_jq "multi-line reply: FIRST line retained" "$ENVELOPE" \
    '.result.value | split("\n") | .[0]' '| Check | Verdict | Notes |'
assert_jq "multi-line reply: TRAILING sentinel retained (the bug)" "$ENVELOPE" \
    '.result.value | split("\n") | last' 'REVIEW_VERDICT: APPROVED'
assert_jq "multi-line reply: all 5 lines retained" "$ENVELOPE" \
    '.result.value | split("\n") | length' '5'

# Multiple text blocks in one message are joined, not dropped.
FIXTURE_BLOCKS="$BASE_TMP/agent_end_blocks.jsonl"
cat >"$FIXTURE_BLOCKS" <<'EOF'
{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"first block"},{"type":"tool_use","name":"read"},{"type":"text","text":"REVIEW_VERDICT: CHANGES_REQUESTED"}]}]}
EOF
export FIXTURE_PATH="$FIXTURE_BLOCKS"
run_dispatch
assert_jq "multi-block reply: blocks joined, sentinel retained" "$ENVELOPE" \
    '.result.value' 'first block
REVIEW_VERDICT: CHANGES_REQUESTED'

# The LAST assistant message is the reply — earlier ones must not win.
FIXTURE_TURNS="$BASE_TMP/agent_end_turns.jsonl"
cat >"$FIXTURE_TURNS" <<'EOF'
{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"let me look at the code"}]},{"role":"user","content":[{"type":"text","text":"tool result"}]},{"role":"assistant","content":[{"type":"text","text":"done\nREVIEW_VERDICT: APPROVED"}]}]}
EOF
export FIXTURE_PATH="$FIXTURE_TURNS"
run_dispatch
assert_jq "multi-turn: last assistant message wins" "$ENVELOPE" \
    '.result.value | split("\n") | last' 'REVIEW_VERDICT: APPROVED'

# ── Case 7: pi per-message usage is summed into the envelope ────────────────
# pi emits NO top-level agent_end.usage and no {"type":"usage"} event — it
# reports usage per assistant message in its own vocabulary
# (input/output/cacheRead/cacheWrite + cost.total). Shape captured verbatim
# from a live pi 0.80.10 run. Before this, every pi call reported
# input_tokens 0 / cost_usd 0.0, making harness cost comparison impossible.
FIXTURE_USAGE="$BASE_TMP/agent_end_usage.jsonl"
cat >"$FIXTURE_USAGE" <<'EOF'
{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"turn one"}],"usage":{"input":420,"output":5,"cacheRead":10,"cacheWrite":2,"totalTokens":425,"cost":{"input":0.00105,"output":0.000075,"total":0.001125}}},{"role":"assistant","content":[{"type":"text","text":"final answer"}],"usage":{"input":80,"output":15,"cacheRead":5,"cacheWrite":3,"totalTokens":95,"cost":{"total":0.002}}}]}
EOF
export FIXTURE_PATH="$FIXTURE_USAGE"
export STUB_STDERR="warning: cold session — fetching model catalog"
run_dispatch
assert_jq "pi usage: input summed across turns" "$ENVELOPE" '.usage.input_tokens' '500'
assert_jq "pi usage: output summed across turns" "$ENVELOPE" '.usage.output_tokens' '20'
assert_jq "pi usage: cacheRead → cache_read_input_tokens" \
    "$ENVELOPE" '.usage.cache_read_input_tokens' '15'
assert_jq "pi usage: cacheWrite → cache_creation_input_tokens" \
    "$ENVELOPE" '.usage.cache_creation_input_tokens' '5'
assert_jq "pi usage: cost.total summed (was always 0.0)" \
    "$ENVELOPE" '.usage.cost_usd' '0.003125'
assert_jq "pi usage: last assistant message still wins for value" \
    "$ENVELOPE" '.result.value' 'final answer'

# No usage anywhere → zeros, never a crash.
export FIXTURE_PATH="$FIXTURE_OK"
run_dispatch
assert_jq "no per-message usage: falls back to agent_end usage" \
    "$ENVELOPE" '.usage.input_tokens' '120'

# ── Case 8: absent num_turns must record as JSON null, never a fabricated
# "1 turn" sentinel (masking-default discipline; pins the contract a stale
# reference diff would have silently reverted to `// 1`).
FIXTURE_NO_TURNS="$BASE_TMP/agent_end_no_turns.jsonl"
cat >"$FIXTURE_NO_TURNS" <<'EOF'
{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"no turn count here"}]}]}
EOF
export FIXTURE_PATH="$FIXTURE_NO_TURNS"
unset STUB_STDERR 2>/dev/null || true
run_dispatch
assert_jq "absent num_turns: records as null, not 1" "$ENVELOPE" '.usage.num_turns' 'null'

# ── Watchdog: dead-stream cap (Trigger 3, CODEGEN_CALL_STREAM_IDLE_SECS) ─────
# Stub pgrep on PATH so child-presence is deterministic regardless of host OS.
PGREP_STUB_DIR="$BASE_TMP/pgrep_stub_bin"
mkdir -p "$PGREP_STUB_DIR"

# (aa) Dead stream: no output growth AND no live tool subprocess (pgrep empty)
# → killed after STREAM_IDLE_SECS with the "stream idle" reason.
cat >"$PGREP_STUB_DIR/pi" <<'WDSTALLSTUB'
#!/usr/bin/env bash
# Stub pi: no output, hang forever.
sleep 3600
WDSTALLSTUB
chmod +x "$PGREP_STUB_DIR/pi"
cat >"$PGREP_STUB_DIR/pgrep" <<'PGREPEMPTY'
#!/usr/bin/env bash
# Always report no children — simulates a dead socket with no tool running.
exit 1
PGREPEMPTY
chmod +x "$PGREP_STUB_DIR/pgrep"

WD_AA_EXIT=0
WD_AA_START=$(date +%s)
(
    export PATH="$PGREP_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE_OK"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=900
    export CODEGEN_CALL_STREAM_IDLE_SECS=2
    unset STUB_STDERR 2>/dev/null || true
    bash "$DISPATCH" 2>"$BASE_TMP/wd_aa_stderr.log"
) >"$BASE_TMP/wd_aa_envelope.json" || WD_AA_EXIT=$?
WD_AA_ELAPSED=$(($(date +%s) - WD_AA_START))

if [[ "$WD_AA_EXIT" -eq 0 ]]; then
    pass=$((pass + 1))
else
    printf 'FAIL: (aa) dead-stream cap: dispatch exits 0 — got %d\n' "$WD_AA_EXIT"
    fail=$((fail + 1))
fi

if grep -q "stream idle" "$BASE_TMP/wd_aa_stderr.log" 2>/dev/null; then
    pass=$((pass + 1))
else
    printf 'FAIL: (aa) dead-stream cap: stderr must contain "stream idle"\n  stderr: %s\n' \
        "$(cat "$BASE_TMP/wd_aa_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

if [[ "$WD_AA_ELAPSED" -lt 60 ]]; then
    pass=$((pass + 1))
else
    printf 'FAIL: (aa) dead-stream cap took too long (%ds)\n' "$WD_AA_ELAPSED"
    fail=$((fail + 1))
fi

# (bb) Live-but-quiet: no output growth BUT a tool subprocess IS running
# (pgrep -P non-empty) → the short dead-stream cap must NOT fire; only the
# (much longer) idle backstop governs.
cat >"$PGREP_STUB_DIR/pgrep" <<'PGREPREAL'
#!/usr/bin/env bash
exec /usr/bin/pgrep "$@"
PGREPREAL
chmod +x "$PGREP_STUB_DIR/pgrep"
cat >"$PGREP_STUB_DIR/pi" <<'WDLIVESTUB'
#!/usr/bin/env bash
# Stub pi: spawn a long-lived child (simulates a bash tool subprocess still
# running), emit no output itself, then hang.
sleep 3600 &
wait
WDLIVESTUB
chmod +x "$PGREP_STUB_DIR/pi"

WD_BB_EXIT=0
WD_BB_START=$(date +%s)
(
    export PATH="$PGREP_STUB_DIR:$PATH"
    export FIXTURE_PATH="$FIXTURE_OK"
    export CODEGEN_LOOP=1
    export CODEGEN_CALL_RESULT_GRACE_SECS=30
    export CODEGEN_CALL_IDLE_CAP_SECS=3
    export CODEGEN_CALL_STREAM_IDLE_SECS=2
    unset STUB_STDERR 2>/dev/null || true
    bash "$DISPATCH" 2>"$BASE_TMP/wd_bb_stderr.log"
) >"$BASE_TMP/wd_bb_envelope.json" || WD_BB_EXIT=$?
WD_BB_ELAPSED=$(($(date +%s) - WD_BB_START))

if grep -q "stream idle" "$BASE_TMP/wd_bb_stderr.log" 2>/dev/null; then
    printf 'FAIL: (bb) live-but-quiet: short dead-stream cap must not fire\n  stderr: %s\n' \
        "$(cat "$BASE_TMP/wd_bb_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

if grep -q "idle 3s with no output growth" "$BASE_TMP/wd_bb_stderr.log" 2>/dev/null; then
    pass=$((pass + 1))
else
    printf 'FAIL: (bb) live-but-quiet: expected idle-backstop kill message\n  stderr: %s\n' \
        "$(cat "$BASE_TMP/wd_bb_stderr.log" 2>/dev/null || true)"
    fail=$((fail + 1))
fi

if [[ "$WD_BB_ELAPSED" -ge 3 ]]; then
    pass=$((pass + 1))
else
    printf 'FAIL: (bb) live-but-quiet: killed too early (%ds) — short cap fired despite live subprocess\n' "$WD_BB_ELAPSED"
    fail=$((fail + 1))
fi

# (cc) default: CODEGEN_CALL_STREAM_IDLE_SECS unset → defaults to 300.
if grep -q 'STREAM_IDLE_SECS="${CODEGEN_CALL_STREAM_IDLE_SECS:-300}"' "$DISPATCH"; then
    pass=$((pass + 1))
else
    printf 'FAIL: (cc) default STREAM_IDLE_SECS=300 not found in %s\n' "$DISPATCH"
    fail=$((fail + 1))
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
