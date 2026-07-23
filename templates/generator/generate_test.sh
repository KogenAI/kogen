#!/usr/bin/env bash
# generate_test.sh — unit tests for generate.sh argument validation and safety.
# Cases: (a) no args → exit 1 + Usage:, (b) unknown harness → exit 1,
#        (c) OUTPUT_DIR=$tmp generate.sh claude → exit 0 + tmp non-empty + repo mtime unchanged,
#        (d) PATH without python3 → exit 1 + Python3 error.
# Usage: bash generate_test.sh
# CRITICAL: every case must avoid mutating repo state.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATE_SH="$SCRIPT_DIR/generate.sh"

pass=0
fail=0

_assert_exit() {
    local label="$1"
    local expected_code="$2"
    local actual_code="$3"
    if [ "$actual_code" = "$expected_code" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label — expected exit $expected_code, got $actual_code"
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
        echo "  got: $haystack"
    fi
}

_assert_true() {
    local label="$1"
    local cond="$2" # "true" or "false"
    if [ "$cond" = "true" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
    fi
}

# ── Case (a): no args → exit 1 + "Usage:" on stderr ─────────────────────────

output_a=$(bash "$GENERATE_SH" 2>&1 || true)
bash "$GENERATE_SH" 2>/dev/null >/dev/null
rc_a=$?

_assert_exit "(a) no args exits 1" "1" "$rc_a"
_assert_contains "(a) stderr contains 'Usage:'" "Usage:" "$output_a"

# ── Case (b): unknown harness → exit 1 + "unknown harness" ───────────────────

output_b=$(bash "$GENERATE_SH" unknownharness 2>&1 || true)
rc_b=0
bash "$GENERATE_SH" unknownharness 2>/dev/null >/dev/null || rc_b=$?

_assert_exit "(b) unknown harness exits 1" "1" "$rc_b"
_assert_contains "(b) error contains 'unknown harness'" "unknown harness" "$output_b"

# ── Case (c): OUTPUT_DIR=$tmp → exit 0, tmp non-empty, repo mtime unchanged ──

# Record mtime of templates/generated/ BEFORE the test run.
GENERATED_DIR="$SCRIPT_DIR/../generated"
mtime_before=""
if [ -d "$GENERATED_DIR" ]; then
    mtime_before=$(stat -f %m "$GENERATED_DIR" 2>/dev/null || stat -c %Y "$GENERATED_DIR" 2>/dev/null || echo "unknown")
fi

tmp_c=$(mktemp -d)
trap 'rm -rf "$tmp_c"' EXIT

output_c=$(OUTPUT_DIR="$tmp_c" bash "$GENERATE_SH" claude 2>&1)
rc_c=$?

_assert_exit "(c) OUTPUT_DIR generate.sh claude exits 0" "0" "$rc_c"

# Verify OUTPUT_DIR non-empty (subagent files were written there)
file_count=$(find "$tmp_c" -type f | wc -l | tr -d ' ')
if [ "$file_count" -gt 0 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: (c) OUTPUT_DIR is empty after generate.sh claude"
fi

# Verify repo's templates/generated/ mtime unchanged
if [ -n "$mtime_before" ] && [ "$mtime_before" != "unknown" ] && [ -d "$GENERATED_DIR" ]; then
    mtime_after=$(stat -f %m "$GENERATED_DIR" 2>/dev/null || stat -c %Y "$GENERATED_DIR" 2>/dev/null || echo "unknown")
    if [ "$mtime_before" = "$mtime_after" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: (c) repo templates/generated/ mtime changed — test polluted repo state!"
        echo "  before: $mtime_before  after: $mtime_after"
    fi
else
    # templates/generated/ doesn't exist (fresh checkout) — that's fine
    pass=$((pass + 1))
fi

# ── Case (d): no python3 on PATH → exit 1 + "Python3 is required" ────────────

# Strategy: create a tmp bin dir that has all system tools EXCEPT python3.
# Prepend that dir to PATH so a real python3 cannot be found via `command -v`.
# We DON'T symlink python3 into the tmp dir, so `command -v python3` returns 1.
nopy_dir=$(mktemp -d)
trap 'rm -rf "$nopy_dir"' EXIT

# Symlink everything in /usr/bin and /bin into nopy_dir EXCEPT python3.
for f in /usr/bin/* /bin/*; do
    bname="$(basename "$f")"
    case "$bname" in
    python3 | python3.* | python) ;; # skip all python variants
    *) ln -s "$f" "$nopy_dir/$bname" 2>/dev/null || true ;;
    esac
done

output_d=$(PATH="$nopy_dir" bash "$GENERATE_SH" claude 2>&1 || true)
PATH="$nopy_dir" bash "$GENERATE_SH" claude 2>/dev/null >/dev/null
rc_d=$?

_assert_exit "(d) no python3 on PATH exits 1" "1" "$rc_d"
_assert_contains "(d) error contains 'Python3 is required'" "Python3 is required" "$output_d"

# ── Case (e): generate.sh pi copies harnesses/claude/commands/document.md
# byte-for-byte into pi/prompts/document.md — the single document-prompt
# producer (Claude command source → generated Pi prompt), no separate
# hand-maintained Pi source. OUTPUT_DIR does NOT redirect the pi prompts dir
# (only GENERATED_ROOT/pi/prompts, itself overridable via OCG_GENERATED_DIR,
# does) — use that override to keep this test hermetic. ────────────────────
tmp_e=$(mktemp -d)
trap 'rm -rf "$tmp_e"' EXIT

output_e=$(OCG_GENERATED_DIR="$tmp_e" bash "$GENERATE_SH" pi 2>&1)
rc_e=$?
_assert_exit "(e) OCG_GENERATED_DIR generate.sh pi exits 0" "0" "$rc_e"

generated_doc="$tmp_e/pi/prompts/document.md"
source_doc="$SCRIPT_DIR/../../harnesses/claude/commands/document.md"
if [ -f "$generated_doc" ] && [ -f "$source_doc" ] && cmp -s "$generated_doc" "$source_doc"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: (e) generated pi/prompts/document.md is not byte-identical to harnesses/claude/commands/document.md"
fi

# ── Case (f): the dead tracked Pi-specific document prompt source path stays
# absent — harnesses/pi/pi-prompts/document.md was hard-deleted (zero
# production refs; the generated prompt above is the sole producer). ───────
dead_path="$SCRIPT_DIR/../../harnesses/pi/pi-prompts/document.md"
if [ ! -f "$dead_path" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: (f) dead harnesses/pi/pi-prompts/document.md still present on disk"
fi

echo "$pass passed, $fail failed"
