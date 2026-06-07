#!/usr/bin/env bash
# gitignore_test.sh — unit tests for gitignore.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATION="$SCRIPT_DIR/gitignore.sh"
FIXTURE_BASE="$SCRIPT_DIR/../../../../test_harness/mutations/fixtures/phx_new_skeleton"

passed=0
failed=0
fail_lines=()

assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        fail_lines+=("FAIL: $label")
    fi
}

setup_tmp() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/mut-XXXXXX")"
    cp -R "$FIXTURE_BASE/." "$tmp/"
    echo "$tmp"
}

# Case 1: happy path — appends Optimum section to .gitignore
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
assert ".gitignore has Optimum section" 'grep -qF "# Optimum development/test artifacts" "$tmp/.gitignore"'
rm -rf "$tmp"

# Case 2: idempotent — second invocation is a no-op (file checksum stable)
tmp="$(setup_tmp)"
"$MUTATION" "$tmp" >/dev/null
sha_after_first="$(shasum "$tmp/.gitignore" | awk '{print $1}')"
"$MUTATION" "$tmp" >/dev/null
sha_after_second="$(shasum "$tmp/.gitignore" | awk '{print $1}')"
assert "gitignore.sh second invocation is a no-op" '[ "$sha_after_first" = "$sha_after_second" ]'
rm -rf "$tmp"

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
