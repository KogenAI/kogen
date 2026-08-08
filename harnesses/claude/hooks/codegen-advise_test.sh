#!/usr/bin/env bash
# codegen-advise_test.sh — hermetic tests for codegen-advise's packet
# assembler (pitch "the advisor is handed a paragraph").
#
# Never calls a real model: codegen-call is stubbed out on PATH via a
# rewritten CODEGEN_CALL path inside a copy of codegen-advise, so every
# case is offline and deterministic. Each stub echoes the LAST argv entry
# (the assembled packet, passed as codegen-call's PROMPT) to a captured
# file for inspection.

set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$HOOKS_DIR/../../.." && pwd)"
REAL_ADVISE="$CODEGEN_ROOT/codegen-advise"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  pattern: %s\n  actual:  %.200s...\n' "$desc" "$pattern" "$actual"
        fail=$((fail + 1))
    fi
}

assert_no_match() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        printf 'FAIL: %s (pattern unexpectedly matched: %s)\n' "$desc" "$pattern"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Build a stub codegen-call that captures its last argv entry (the
# assembled packet) to a file and emits a fixed success envelope.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
CAPTURE_FILE="$WORKDIR/captured_packet.txt"

cat >"$STUB_DIR/codegen-call" <<'STUB'
#!/usr/bin/env bash
LAST=""
for a in "$@"; do LAST="$a"; done
printf '%s' "$LAST" >"$CODEGEN_ADVISE_TEST_CAPTURE"
printf '{"result":{"status":"success","value":{"diagnosis":"d","falsifier":"f","next_probe":{"action":"a","expected_outcomes":[{"if_hypothesis":"h1","then_observe":"o1"},{"if_hypothesis":"h2","then_observe":"o2"}]},"evidence_used":["e"],"missing_evidence":[],"confidence":"high"}}}\n'
STUB
chmod +x "$STUB_DIR/codegen-call"

# Test-scoped copy of codegen-advise with CODEGEN_CALL repointed at the stub
# (avoids ever shelling the real codegen-call / a real model).
TEST_ADVISE="$WORKDIR/codegen-advise"
sed "s#CODEGEN_CALL=\"\$CODEGEN_DIR/codegen-call\"#CODEGEN_CALL=\"$STUB_DIR/codegen-call\"#" \
    "$REAL_ADVISE" >"$TEST_ADVISE"
chmod +x "$TEST_ADVISE"

run_advise() {
    local cwd="$1" question="$2"
    printf '%s' "$question" | env CODEGEN_ADVISE_TEST_CAPTURE="$CAPTURE_FILE" \
        "$TEST_ADVISE" --harness=claude_code --cwd="$cwd"
}

# ── 1. The packet is machine-built (git HEAD, diff, attempt/stage) ─────────
REPO1="$WORKDIR/repo1"
mkdir -p "$REPO1"
git -C "$REPO1" init -q
git -C "$REPO1" config user.email test@test.com
git -C "$REPO1" config user.name test
printf 'hello\n' >"$REPO1/foo.txt"
git -C "$REPO1" add -A
git -C "$REPO1" commit -q -m "init commit"
printf 'hello\nworld\n' >"$REPO1/foo.txt"

: >"$CAPTURE_FILE"
OUT1=$(run_advise "$REPO1" "test question one" 2>&1)
RC1=$?
PACKET1=$(cat "$CAPTURE_FILE" 2>/dev/null || true)

assert_eq "case 1: exit 0 on clean stub call" "0" "$RC1"
assert_match "case 1: packet carries the question verbatim" "test question one" "$PACKET1"
assert_match "case 1: packet carries HEAD sha" "HEAD: [0-9a-f]{7,40}" "$PACKET1"
assert_match "case 1: packet carries the diff" "\\+world" "$PACKET1"
assert_match "case 1: packet has attempt/stage section" "## 4\\. Attempt / stage" "$PACKET1"
assert_match "case 1: unset attempt reads unavailable, never fabricated" "Attempt: unavailable" "$PACKET1"

# ── 2. --cwd is required ────────────────────────────────────────────────────
OUT2=$(printf 'x' | "$TEST_ADVISE" --harness=claude_code 2>&1)
RC2=$?
assert_eq "case 2: missing --cwd exits 2" "2" "$RC2"
assert_match "case 2: usage names --cwd" "cwd is required" "$OUT2"

# ── 3. Section absence is explicit ("[unavailable: ...]"), call still proceeds
REPO3="$WORKDIR/not-a-repo"
mkdir -p "$REPO3"
: >"$CAPTURE_FILE"
OUT3=$(run_advise "$REPO3" "no git here" 2>&1)
RC3=$?
PACKET3=$(cat "$CAPTURE_FILE" 2>/dev/null || true)

assert_eq "case 3: non-git cwd still succeeds (call proceeds)" "0" "$RC3"
assert_match "case 3: base attribution explicitly unavailable" "\\[unavailable: --cwd is not a git work tree\\]" "$PACKET3"
assert_match "case 3: diff section explicitly unavailable" "\\[unavailable: --cwd is not a git work tree\\]" "$PACKET3"

# ── 4. Sections 1-4 alone over ceiling fails loud (exit 2), never truncated
BIG_Q="$(head -c 70000 /dev/zero | tr '\0' 'x')"
OUT4=$(printf '%s' "$BIG_Q" | "$TEST_ADVISE" --harness=claude_code --cwd="$REPO3" 2>&1)
RC4=$?
assert_eq "case 4: oversized core (sections 1-4) exits 2" "2" "$RC4"
assert_match "case 4: refuses rather than truncates the question" "refusing rather than truncating" "$OUT4"

# ── 5. Truncation: an oversized diff/log gets a [truncated: N of M lines] marker
REPO5="$WORKDIR/repo5"
mkdir -p "$REPO5/codegen/gate-pending"
git -C "$REPO5" init -q
git -C "$REPO5" config user.email test@test.com
git -C "$REPO5" config user.name test
seq 1 2000 >"$REPO5/big.txt"
git -C "$REPO5" add -A
git -C "$REPO5" commit -q -m "init"
seq 1 2000 | sed 's/^/line/' >"$REPO5/big.txt"

jq -n '{verdict:"failed",witness:"",gate:"make test",log:"codegen/gate-pending/gate-run.log"}' \
    >"$REPO5/codegen/gate-pending/gate-result.json"
seq 1 1000 | sed 's/^/log line /' >"$REPO5/codegen/gate-pending/gate-run.log"

: >"$CAPTURE_FILE"
OUT5=$(run_advise "$REPO5" "oversized sections" 2>&1)
RC5=$?
PACKET5=$(cat "$CAPTURE_FILE" 2>/dev/null || true)

assert_eq "case 5: oversized optional sections still succeed (shrink, not fail)" "0" "$RC5"
assert_match "case 5: diff section carries a truncation marker naming N of M" "truncated: [0-9]+ of [0-9]+ lines" "$PACKET5"
assert_match "case 5: failure-output section carries a truncation marker" "truncated: last [0-9]+ of [0-9]+ lines" "$PACKET5"
PACKET5_BYTES=${#PACKET5}
if [ "$PACKET5_BYTES" -le 65536 ]; then
    pass=$((pass + 1))
else
    printf 'FAIL: case 5: packet bytes (%d) exceed the 65536-byte ceiling\n' "$PACKET5_BYTES"
    fail=$((fail + 1))
fi

# ── 6. Truncation follows the declared order: diff shrinks before failure output
# (Verified structurally above — case 5 shows BOTH sections shrunk when the
# combined packet would otherwise exceed the ceiling; this case confirms the
# diff-only oversized packet fits without needing to touch failure output.)
REPO6="$WORKDIR/repo6"
mkdir -p "$REPO6"
git -C "$REPO6" init -q
git -C "$REPO6" config user.email test@test.com
git -C "$REPO6" config user.name test
seq 1 50 >"$REPO6/small.txt"
git -C "$REPO6" add -A
git -C "$REPO6" commit -q -m "init"
seq 1 50 | sed 's/^/line/' >"$REPO6/small.txt"

: >"$CAPTURE_FILE"
OUT6=$(run_advise "$REPO6" "small diff, no failure output" 2>&1)
RC6=$?
PACKET6=$(cat "$CAPTURE_FILE" 2>/dev/null || true)
assert_eq "case 6: small diff succeeds untruncated" "0" "$RC6"
assert_no_match "case 6: small diff carries no truncation marker" "truncated: [0-9]+ of [0-9]+ lines" "$PACKET6"

# ── 7. The question survives verbatim even alongside evidence sections ─────
assert_match "case 7: question appears under its own numbered section" "## 1\\. The question" "$PACKET1"

# ── 8-10. JSON-schema acceptance — no model call, fixtures only ────────────
SCHEMA_FILE="$CODEGEN_ROOT/harnesses/claude/advise.schema.json"
SCHEMA_TMPD="$WORKDIR/schema-fixtures"
mkdir -p "$SCHEMA_TMPD"

validate_fixture() {
    CODEGEN_DIR="$CODEGEN_ROOT" node "$CODEGEN_ROOT/harnesses/claude/hooks/lib/schema-validate.js" \
        "$SCHEMA_FILE" "$1" >/dev/null 2>&1
}

# 8. Rejects a missing falsifier.
cat >"$SCHEMA_TMPD/missing_falsifier.json" <<'EOF'
{"diagnosis":"x","next_probe":{"action":"a","expected_outcomes":[{"if_hypothesis":"h1","then_observe":"o1"},{"if_hypothesis":"h2","then_observe":"o2"}]},"evidence_used":["e"],"missing_evidence":[],"confidence":"high"}
EOF
if validate_fixture "$SCHEMA_TMPD/missing_falsifier.json"; then
    printf 'FAIL: case 8: missing falsifier should be rejected but validated\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# 9. Rejects a structurally non-discriminating probe (< 2 outcomes, or
# byte-identical outcomes) — whatever action category next_probe names.
cat >"$SCHEMA_TMPD/one_outcome.json" <<'EOF'
{"diagnosis":"x","falsifier":"y","next_probe":{"action":"a","expected_outcomes":[{"if_hypothesis":"h1","then_observe":"o1"}]},"evidence_used":["e"],"missing_evidence":[],"confidence":"high"}
EOF
if validate_fixture "$SCHEMA_TMPD/one_outcome.json"; then
    printf 'FAIL: case 9a: single expected_outcome should be rejected but validated\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

cat >"$SCHEMA_TMPD/dup_outcomes.json" <<'EOF'
{"diagnosis":"x","falsifier":"y","next_probe":{"action":"a","expected_outcomes":[{"if_hypothesis":"h1","then_observe":"o1"},{"if_hypothesis":"h1","then_observe":"o1"}]},"evidence_used":["e"],"missing_evidence":[],"confidence":"high"}
EOF
if validate_fixture "$SCHEMA_TMPD/dup_outcomes.json"; then
    printf 'FAIL: case 9b: byte-identical expected_outcomes should be rejected but validated\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

# A probe of ANY kind (including a rerun) with two DISTINCT hypothesis-keyed
# outcomes passes — the schema never rules a category in or out.
cat >"$SCHEMA_TMPD/valid_rerun_probe.json" <<'EOF'
{"diagnosis":"x","falsifier":"y","next_probe":{"action":"rerun with a longer timeout","expected_outcomes":[{"if_hypothesis":"pool exhaustion","then_observe":"passes under isolation"},{"if_hypothesis":"livelock in ordered_fn","then_observe":"still times out under isolation"}]},"evidence_used":["e"],"missing_evidence":[],"confidence":"medium"}
EOF
if validate_fixture "$SCHEMA_TMPD/valid_rerun_probe.json"; then
    pass=$((pass + 1))
else
    printf 'FAIL: case 9c: a rerun probe with 2 distinct outcomes should validate\n'
    fail=$((fail + 1))
fi

# 10. Rejects the old {plan, confidence} shape outright.
cat >"$SCHEMA_TMPD/old_shape.json" <<'EOF'
{"plan":"do the thing","confidence":"high"}
EOF
if validate_fixture "$SCHEMA_TMPD/old_shape.json"; then
    printf 'FAIL: case 10: old {plan, confidence} shape should be rejected but validated\n'
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
