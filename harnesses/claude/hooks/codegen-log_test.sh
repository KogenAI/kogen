#!/bin/bash
# codegen-log_test.sh — unit tests for codegen-log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CODEGEN_LOG="$CODEGEN_ROOT/codegen-log"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

make_stub() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

ROOT="$TMP_DIR/root"
mkdir -p "$ROOT/codegen/logging"
cp "$CODEGEN_LOG" "$ROOT/codegen-log"
chmod +x "$ROOT/codegen-log"

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
make_stub "$STUB_BIN/git" 'if [ "$1" = "-C" ]; then shift 2; fi; if [ "$1" = "rev-parse" ] && [ "$2" = "--short" ] && [ "$3" = "HEAD" ]; then case "$PWD" in *codegen/rules*) printf "ctxabc\n" ;; *) printf "proj123\n" ;; esac; exit 0; fi; command git "$@"'
make_stub "$STUB_BIN/claude" 'printf "claude 1.2.3\n"'
export PATH="$STUB_BIN:$PATH"

# Test 1: init writes Version Stamp only and prints the file path.
init_out="$(cd "$ROOT" && ./codegen-log init --slug canonical)"
init_path="$(printf '%s' "$init_out" | tail -n 1)"
assert "init printed path" "0" "$([ -f "$init_path" ] && printf 0 || printf 1)"
assert "init wrote version stamp" "0" "$([ "$(grep -c '^## Version Stamp$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"
assert "init omitted plan header" "0" "$([ "$(grep -c '^## Plan$' "$init_path")" -eq 0 ] && printf 0 || printf 1)"
assert "init stamped project hash" "0" "$([ "$(grep -c '^- project: proj123$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"
assert "init stamped claude version" "0" "$([ "$(grep -c '^- claude: claude 1.2.3$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"

# Test 2: section inserts developer body between Files Modified and reviewer.
fixture="$TMP_DIR/fixture.md"
cat >"$fixture" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: proj123
- claude: claude 1.2.3
- stamped_at: 2026-06-29T00:00:00Z

## Plan

old plan

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |

## Files Modified

- a

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅
EOF

export CODEGEN_LOG_PATH="$fixture"
export AGENT_TYPE="developer-phoenix-backend"
section_out="$(cd "$ROOT" && ./codegen-log section --body @- <<'EOF'
## developer-phoenix-backend Section

### What I Learned This Step
- inserted by test
EOF
)"
section_path="$(printf '%s' "$section_out" | tail -n 1)"
assert "section wrote target file" "0" "$([ "$section_path" = "$fixture" ] && printf 0 || printf 1)"
assert "section inserted developer header" "0" "$([ "$(grep -c '^## developer-phoenix-backend Section$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"
assert "section preserved reviewer header" "0" "$([ "$(grep -c '^## reviewer-phoenix Section$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"
assert "section landed before reviewer" "0" "$([ $(grep -n '^## developer-phoenix-backend Section$' "$fixture" | cut -d: -f1) -lt $(grep -n '^## reviewer-phoenix Section$' "$fixture" | cut -d: -f1) ] && printf 0 || printf 1)"
assert "section body preserved" "0" "$([ "$(grep -c '^### What I Learned This Step$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"

# Test 3: rerun replaces in place instead of duplicating the header.
export AGENT_TYPE="developer-phoenix-backend"
./codegen-log section --body @- <<'EOF'
## developer-phoenix-backend Section

### What I Learned This Step
- updated body
EOF

assert "rerun keeps one developer header" "0" "$([ "$(grep -c '^## developer-phoenix-backend Section$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"
assert "rerun updated body" "0" "$([ "$(grep -c '^- updated body$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
