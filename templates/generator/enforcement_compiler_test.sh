#!/bin/bash
# enforcement_compiler_test.sh — unit tests for enforcement_compiler.py.
#
# Tests (14):
#   1:  parse valid registry (3 entries loaded)
#   2:  dialect translation bash: \\s → [[:space:]] in generated .sh
#   3:  match_all AND logic: two grep -qE calls joined with &&
#   4:  generated:false entry skipped (no file emitted)
#   5:  forbidden backreference rejected
#   6:  forbidden lookahead rejected
#   7:  empty registry produces no output files
#   8:  generated .sh passes bash -n syntax check
#   9:  generated .sh HOOK-MANIFEST headers match registry fields
#  10:  index.ts update wraps entries in BEGIN/END markers
#  11:  index.ts update is idempotent (re-run produces no diff)
#  12:  no-python-json.ts (match_all) generates correctly in TypeScript
#  13:  message backtick escaped in bash deny call
#  14:  match_all ts: both patterns present in generated .ts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPILER="$SCRIPT_DIR/enforcement_compiler.py"
REGISTRY="$SCRIPT_DIR/../../shared/enforcement/registry.yaml"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS: %s\n' "$desc"
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
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle not found: %s\n' "$desc" "$needle"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  needle found (should not be): %s\n' "$desc" "$needle"
        fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# ── Test 1: parse valid registry (3 entries loaded) ──────────────────────────

tmpdir=$(mktemp -d /tmp/ec_test_XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

python3 "$COMPILER" \
    --registry "$REGISTRY" \
    --bash-out "$tmpdir/bash" \
    --ts-out "$tmpdir/ts" \
    --index "$tmpdir/index.ts" \
    --dry-run >"$tmpdir/dry_run.txt" 2>&1 || true

count=$(
    grep -c "^===" "$tmpdir/dry_run.txt" 2>/dev/null
    true
)
assert_eq "parse valid registry: 6 sections (3 bash + 3 ts)" "6" "$count"

# ── Test 2: dialect translation bash: \s → [[:space:]] ───────────────────────

bash_catpipe=$(grep "grep -qE" "$tmpdir/dry_run.txt" | head -1 || true)
assert_contains "bash dialect: \\s → [[:space:]]" "[[:space:]]" "$bash_catpipe"
assert_not_contains "bash dialect: no bare \\s in bash pattern" '\s' "$bash_catpipe"

# ── Test 3: match_all AND logic in bash ───────────────────────────────────────

# no-python-json has match_all with 2 patterns → 2 grep -qE calls joined by &&
python_section=$(awk '/=== .*no-python-json\.sh/,/=== .*no-python-json\.ts/' "$tmpdir/dry_run.txt" || true)
grep_count=$(
    printf '%s' "$python_section" | grep -c "grep -qE" 2>/dev/null
    true
)
assert_eq "match_all: 2 grep -qE calls in bash" "2" "$grep_count"
assert_contains "match_all: && joins conditions" "&&" "$python_section"

# ── Test 4: generated:false entry skipped ────────────────────────────────────

# Create a minimal registry with generated:false
cat >"$tmpdir/registry_skip.yaml" <<'YAML'
- id: should-skip
  generated: false
  event: PreToolUse
  tool_guard: Bash
  match: "foo"
  message: "skip me"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

python3 "$COMPILER" \
    --registry "$tmpdir/registry_skip.yaml" \
    --bash-out "$tmpdir/skip_bash" \
    --ts-out "$tmpdir/skip_ts" \
    --index "$tmpdir/skip_index.ts" \
    --dry-run >"$tmpdir/skip_out.txt" 2>&1 || true

section_count=$(
    grep -c "^===" "$tmpdir/skip_out.txt" 2>/dev/null
    true
)
assert_eq "generated:false: no files emitted" "0" "$section_count"

# ── Test 5: forbidden backreference rejected ─────────────────────────────────

cat >"$tmpdir/registry_backref.yaml" <<'YAML'
- id: bad-backref
  generated: true
  event: PreToolUse
  tool_guard: Bash
  match: "(foo)\\1"
  message: "test"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

set +e
python3 "$COMPILER" \
    --registry "$tmpdir/registry_backref.yaml" \
    --bash-out "$tmpdir/backref_bash" \
    --ts-out "$tmpdir/backref_ts" \
    --index "$tmpdir/backref_index.ts" \
    --dry-run >"$tmpdir/backref_out.txt" 2>&1
backref_rc=$?
set -e
assert_eq "forbidden backreference: non-zero exit" "1" "$((backref_rc != 0 ? 1 : 0))"

# ── Test 6: forbidden lookahead rejected ─────────────────────────────────────

cat >"$tmpdir/registry_lookahead.yaml" <<'YAML'
- id: bad-lookahead
  generated: true
  event: PreToolUse
  tool_guard: Bash
  match: "foo(?=bar)"
  message: "test"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

set +e
python3 "$COMPILER" \
    --registry "$tmpdir/registry_lookahead.yaml" \
    --bash-out "$tmpdir/lookahead_bash" \
    --ts-out "$tmpdir/lookahead_ts" \
    --index "$tmpdir/lookahead_index.ts" \
    --dry-run >"$tmpdir/lookahead_out.txt" 2>&1
lookahead_rc=$?
set -e
assert_eq "forbidden lookahead: non-zero exit" "1" "$((lookahead_rc != 0 ? 1 : 0))"

# ── Test 7: empty registry produces no files ─────────────────────────────────

cat >"$tmpdir/registry_empty.yaml" <<'YAML'
[]
YAML

python3 "$COMPILER" \
    --registry "$tmpdir/registry_empty.yaml" \
    --bash-out "$tmpdir/empty_bash" \
    --ts-out "$tmpdir/empty_ts" \
    --index "$tmpdir/empty_index.ts" \
    --dry-run >"$tmpdir/empty_out.txt" 2>&1

empty_count=$(
    grep -c "^===" "$tmpdir/empty_out.txt" 2>/dev/null
    true
)
assert_eq "empty registry: no files emitted" "0" "$empty_count"

# ── Test 8: generated .sh passes bash -n syntax check ────────────────────────

mkdir -p "$tmpdir/real_bash" "$tmpdir/real_ts"
cp "$SCRIPT_DIR/../../harnesses/pi/pi-extensions/enforcement/src/index.ts" "$tmpdir/real_index.ts" 2>/dev/null || touch "$tmpdir/real_index.ts"

python3 "$COMPILER" \
    --registry "$REGISTRY" \
    --bash-out "$tmpdir/real_bash" \
    --ts-out "$tmpdir/real_ts" \
    --index "$tmpdir/real_index.ts" >/dev/null 2>&1

syntax_ok=true
for f in "$tmpdir/real_bash"/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
        syntax_ok=false
        break
    fi
done
assert_eq "generated .sh: bash -n syntax check passes" "true" "$syntax_ok"

# ── Test 9: generated .sh HOOK-MANIFEST headers match registry ───────────────

event=$(grep "^# event:" "$tmpdir/real_bash/no-cat-pipe.sh" | head -1 | awk '{print $3}')
assert_eq "HOOK-MANIFEST event matches registry" "PreToolUse" "$event"

surface=$(grep "^# surface:" "$tmpdir/real_bash/no-cat-pipe.sh" | head -1 | awk '{print $3}')
assert_eq "HOOK-MANIFEST surface matches registry" "user_global" "$surface"

signal=$(grep "^# signal:" "$tmpdir/real_bash/no-git-stash.sh" | head -1 | awk '{print $3}')
assert_eq "HOOK-MANIFEST signal matches registry" "none" "$signal"

# ── Test 10: index.ts update wraps entries in BEGIN/END markers ───────────────

assert_contains "index.ts: BEGIN marker present" "// BEGIN-GENERATED-ENFORCEMENT-BLOCK" "$(cat "$tmpdir/real_index.ts")"
assert_contains "index.ts: END marker present" "// END-GENERATED-ENFORCEMENT-BLOCK" "$(cat "$tmpdir/real_index.ts")"
assert_contains "index.ts: no-cat-pipe import inside block" "registerNoCatPipe" "$(cat "$tmpdir/real_index.ts")"

# ── Test 11: index.ts update is idempotent ────────────────────────────────────

cp "$tmpdir/real_index.ts" "$tmpdir/real_index_orig.ts"
python3 "$COMPILER" \
    --registry "$REGISTRY" \
    --bash-out "$tmpdir/real_bash2" \
    --ts-out "$tmpdir/real_ts2" \
    --index "$tmpdir/real_index.ts" >/dev/null 2>&1

if diff -q "$tmpdir/real_index_orig.ts" "$tmpdir/real_index.ts" >/dev/null 2>&1; then
    printf 'PASS: index.ts update is idempotent\n'
    pass=$((pass + 1))
else
    printf 'FAIL: index.ts update is NOT idempotent\n'
    diff "$tmpdir/real_index_orig.ts" "$tmpdir/real_index.ts" || true
    fail=$((fail + 1))
fi

# ── Test 12: no-python-json.ts generated correctly ────────────────────────────

assert_contains "no-python-json.ts: first pattern present" "python3?" "$(cat "$tmpdir/real_ts/no-python-json.ts")"
assert_contains "no-python-json.ts: second pattern present" "import" "$(cat "$tmpdir/real_ts/no-python-json.ts")"

# ── Test 13: message backtick escaped in bash deny call ──────────────────────

# The deny call line contains escaped backticks (\`) inside double quotes.
catpipe_content=$(cat "$tmpdir/real_bash/no-cat-pipe.sh")
assert_contains "bash: backticks escaped in deny message" 'instead of \`cat' "$catpipe_content"

# ── Test 14: match_all ts: both patterns in generated .ts ─────────────────────

ts_python=$(cat "$tmpdir/real_ts/no-python-json.ts")
assert_contains "ts match_all: pattern 1 present" "python3?" "$ts_python"
assert_contains "ts match_all: && present" "&&" "$ts_python"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
