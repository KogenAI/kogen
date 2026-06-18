#!/usr/bin/env bash
# install_failloud_test.sh — assert the 3 install.sh robustness sites fail loud:
#  (1) pi-ext npm install no longer masked by `| sed`; captures exit + exit 1 on fail
#  (2) prettier errors dumped (mktemp/cat stderr), still non-fatal
#  (3) manifest-lib.sh source guarded by [[ -f ]] + exit 1 BEFORE the source
# Pure source-grep — hermetic, no install run.
set -euo pipefail

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

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$CODEGEN_DIR/install.sh"

# (1) pi-ext npm fail-loud
assert "pi-ext npm masking pipe removed" \
    '! grep -qF "npm install --prefer-offline 2>&1 | sed" "$INSTALL"'
assert "pi-ext npm failure captured" \
    'grep -qF "_pi_ext_install_failed" "$INSTALL"'

# (2) prettier observable-non-fatal
assert "prettier 2>/dev/null || true suppression removed" \
    '! grep -qF "\"$CODEGEN_DIR/shared\" 2>/dev/null || true" "$INSTALL"'
assert "prettier stderr dumped on failure" \
    'grep -qF "_prettier_err" "$INSTALL"'

# (3) manifest-lib.sh guard precedes source (line-order check)
guard_ln="$(grep -nF '[[ ! -f "$CODEGEN_DIR/templates/generator/manifest-lib.sh" ]]' "$INSTALL" | head -1 | cut -d: -f1)"
src_ln="$(grep -nF 'source "$CODEGEN_DIR/templates/generator/manifest-lib.sh"' "$INSTALL" | head -1 | cut -d: -f1)"
assert "manifest-lib.sh existence guard present" '[ -n "$guard_ln" ]'
assert "manifest-lib.sh source present" '[ -n "$src_ln" ]'
assert "guard precedes source" '[ -n "$guard_ln" ] && [ -n "$src_ln" ] && [ "$guard_ln" -lt "$src_ln" ]'

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
