#!/usr/bin/env bash
# manifest-lib_test.sh — unit tests for manifest-lib.sh helpers.
# Sources manifest-lib.sh, sets CODEGEN_DIR to a per-test tmp dir with a stub
# manifest.yaml. Uses the trap pattern to clean tmp on EXIT.
# Each case runs in a subshell to isolate CODEGEN_DIR mutations.
# Usage: bash manifest-lib_test.sh
# Expects: yq on PATH.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB_YAML="$SCRIPT_DIR/test_fixtures/manifest_stub.yaml"

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

_assert_line_count() {
    local label="$1"
    local expected_count="$2"
    local content="$3"
    local actual_count
    actual_count=$(echo "$content" | grep -c . || true)
    if [ "$actual_count" = "$expected_count" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label"
        echo "  expected $expected_count lines, got $actual_count"
        echo "  content: $content"
    fi
}

# ── Setup: each test creates its own CODEGEN_DIR tmp ──────────────────────────

_setup_tmp() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/harnesses/stub"
    cp "$STUB_YAML" "$tmpdir/harnesses/stub/manifest.yaml"
    echo "$tmpdir"
}

# ── Test: manifest_get returns scalar ─────────────────────────────────────────

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    # shellcheck source=templates/generator/manifest-lib.sh
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_get stub '.harness'
)
_assert_eq "manifest_get '.harness' returns 'stub'" "stub" "$result"

# ── Test: manifest_launchers returns 2 lines ──────────────────────────────────

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_launchers stub
)
_assert_line_count "manifest_launchers returns 2 lines" "2" "$result"
_assert_contains "manifest_launchers line 1 contains 'stub-build'" "stub-build" "$result"
_assert_contains "manifest_launchers line 2 contains 'stub-debug'" "stub-debug" "$result"

# ── Test: manifest_completions returns 2 entries ──────────────────────────────

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_completions stub
)
_assert_line_count "manifest_completions returns 2 entries" "2" "$result"
_assert_contains "manifest_completions contains '_stub-build'" "_stub-build" "$result"
_assert_contains "manifest_completions contains '_stub-debug'" "_stub-debug" "$result"

# ── Test: manifest_modes returns 'build' and 'debug' ─────────────────────────

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_modes stub
)
_assert_contains "manifest_modes contains 'build'" "build" "$result"
_assert_contains "manifest_modes contains 'debug'" "debug" "$result"
_assert_line_count "manifest_modes returns 2 mode names" "2" "$result"

# ── Test: manifest_mode_get returns nested scalar ─────────────────────────────

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_mode_get stub build tools_header
)
_assert_eq "manifest_mode_get stub build tools_header" \
    "shared/tools-headers/build.txt" "$result"

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_mode_get stub debug system_prompt_file
)
_assert_eq "manifest_mode_get stub debug system_prompt_file" \
    "harnesses/stub/stub-debug-system-prompt.txt" "$result"

# ── Test: manifest_launchers src/name format (each line is "src name") ────────

result=$(
    tmpdir=$(_setup_tmp)
    trap 'rm -rf "$tmpdir"' EXIT
    export CODEGEN_DIR="$tmpdir"
    source "$SCRIPT_DIR/manifest-lib.sh"
    manifest_launchers stub | head -1
)
# First launcher: "harnesses/stub/stub-build.sh stub-build"
_assert_contains "manifest_launchers line has src and name" "harnesses/stub/stub-build.sh" "$result"
_assert_contains "manifest_launchers line has name token" "stub-build" "$result"

echo "$pass passed, $fail failed"
