#!/usr/bin/env bash
set -euo pipefail
# enforce-hook-rationale_test.sh — unit tests for enforce-hook-rationale.sh.
# Writes fixture registries to $TMP, asserts exit codes and output content.
# Usage: bash enforce-hook-rationale_test.sh
# Expected: yq on PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/enforce-hook-rationale.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

_assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
        echo "  expected: $(printf '%q' "$expected")"
        echo "  actual:   $(printf '%q' "$actual")"
    fi
}

_assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
    fi
}

# ── Case 1: claude entry WITH rationale → exit 0 ──────────────────────────────
cat >"$TMP/case1.yaml" <<'EOF'
- kind: registration
  id: my-hook
  harnesses: claude
  rationale: This explains the hook
EOF
rc=0
bash "$GATE" "$TMP/case1.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "claude+rationale → exit 0" "0" "$rc"

# ── Case 2: claude entry MISSING rationale → exit 1 ───────────────────────────
cat >"$TMP/case2.yaml" <<'EOF'
- kind: registration
  id: missing-hook
  harnesses: claude
EOF
rc=0
bash "$GATE" "$TMP/case2.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "claude+missing rationale → exit 1" "1" "$rc"

# ── Case 3: claude entry with EMPTY-STRING rationale → exit 1 ─────────────────
cat >"$TMP/case3.yaml" <<'EOF'
- kind: registration
  id: empty-hook
  harnesses: claude
  rationale: ""
EOF
rc=0
bash "$GATE" "$TMP/case3.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "claude+empty string rationale → exit 1" "1" "$rc"

# ── Case 4: harnesses:all, no rationale → exit 0 (not claude-only) ────────────
cat >"$TMP/case4.yaml" <<'EOF'
- kind: registration
  id: all-hook
  harnesses: all
EOF
rc=0
bash "$GATE" "$TMP/case4.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "harnesses:all no rationale → exit 0" "0" "$rc"

# ── Case 6: two claude entries BOTH with rationale → exit 0 ───────────────────
cat >"$TMP/case6.yaml" <<'EOF'
- kind: registration
  id: hook-a
  harnesses: claude
  rationale: First rationale
- kind: registration
  id: hook-b
  harnesses: claude
  rationale: Second rationale
EOF
rc=0
bash "$GATE" "$TMP/case6.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "two claude both with rationale → exit 0" "0" "$rc"

# ── Case 7: two claude, one missing → exit 1 AND output names offending id ────
cat >"$TMP/case7.yaml" <<'EOF'
- kind: registration
  id: hook-ok
  harnesses: claude
  rationale: Has one
- kind: registration
  id: hook-bad
  harnesses: claude
EOF
rc=0
out=$(bash "$GATE" "$TMP/case7.yaml" 2>&1) || rc=$?
_assert_eq "two claude one missing → exit 1" "1" "$rc"
_assert_contains "two claude one missing → output names offending id" "hook-bad" "$out"

# ── Case 8: empty registry list → exit 0 ──────────────────────────────────────
cat >"$TMP/case8.yaml" <<'EOF'
[]
EOF
rc=0
bash "$GATE" "$TMP/case8.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "empty registry → exit 0" "0" "$rc"

# ── Case 9: multiple claude all missing → exit 1, names ALL ids ───────────────
cat >"$TMP/case9.yaml" <<'EOF'
- kind: registration
  id: bad-one
  harnesses: claude
- kind: registration
  id: bad-two
  harnesses: claude
- kind: registration
  id: bad-three
  harnesses: claude
EOF
rc=0
out=$(bash "$GATE" "$TMP/case9.yaml" 2>&1) || rc=$?
_assert_eq "multiple claude all missing → exit 1" "1" "$rc"
_assert_contains "multiple missing → output contains bad-one" "bad-one" "$out"
_assert_contains "multiple missing → output contains bad-two" "bad-two" "$out"
_assert_contains "multiple missing → output contains bad-three" "bad-three" "$out"

# ── Case 10: claude rationale single-space → exit 0 (non-empty) ───────────────
cat >"$TMP/case10.yaml" <<'EOF'
- kind: registration
  id: space-hook
  harnesses: claude
  rationale: " "
EOF
rc=0
bash "$GATE" "$TMP/case10.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "claude rationale single-space → exit 0 (non-empty)" "0" "$rc"

# ── Case 11: default registry path (no arg) → exit 0 on live registry ─────────
rc=0
bash "$GATE" >/dev/null 2>&1 || rc=$?
_assert_eq "live registry (no arg) → exit 0" "0" "$rc"

# ── Case 12: claude DENIAL-kind missing rationale → exit 1 (scope=harnesses) ──
cat >"$TMP/case12.yaml" <<'EOF'
- kind: denial
  id: denial-hook
  harnesses: claude
EOF
rc=0
bash "$GATE" "$TMP/case12.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "claude denial-kind missing rationale → exit 1" "1" "$rc"

# ── Case 13: rationale: null literal → exit 1 ─────────────────────────────────
cat >"$TMP/case13.yaml" <<'EOF'
- kind: registration
  id: null-hook
  harnesses: claude
  rationale: null
EOF
rc=0
bash "$GATE" "$TMP/case13.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "rationale: null literal → exit 1" "1" "$rc"

# ── Case 14: claude multi-line rationale → exit 0 ─────────────────────────────
cat >"$TMP/case14.yaml" <<'EOF'
- kind: registration
  id: multiline-hook
  harnesses: claude
  rationale: |
    First line of rationale.
    Second line explaining more detail.
EOF
rc=0
bash "$GATE" "$TMP/case14.yaml" >/dev/null 2>&1 || rc=$?
_assert_eq "claude multi-line rationale → exit 0" "0" "$rc"

# ── Case 15: mixed all-harnesses + one offending claude → exit 1 ──────────────
cat >"$TMP/case15.yaml" <<'EOF'
- kind: registration
  id: all-hook-ok
  harnesses: all
  rationale: All harnesses rationale
- kind: registration
  id: claude-offender
  harnesses: claude
- kind: registration
  id: all-hook-ok
  harnesses: all
EOF
rc=0
out=$(bash "$GATE" "$TMP/case15.yaml" 2>&1) || rc=$?
_assert_eq "mixed all+offending claude → exit 1" "1" "$rc"
_assert_contains "mixed → output names claude-offender" "claude-offender" "$out"

echo "$pass passed, $fail failed"
