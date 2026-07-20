#!/usr/bin/env bash
# mode-context-parity_test.sh — asserts every launcher-backed mode declares
# its context_files set in config.yaml, every declared path exists, every
# mode launcher consumes ROLE_CONTEXT_FILES (rather than hand-rolling
# --append-system-prompt "$(cat ...)"), and resolve_mode_context fails loud
# on a missing declared file.
#
# Modes bound by this contract: babysit, ops, debug, shape, experiment (the
# 5 launcher-backed interactive modes — housekeeper/inspector/usage-rules/
# app_build have no launcher and no --append-system-prompt path, so they are
# NOT part of this gate). shape and experiment are a NAMED EXEMPTION:
# context_files: [] is legal for them (they resolve context dynamically from
# PROJECT_CONTEXT.md § Always Load + citation-prioritized Tier-1, cap 6, via
# harnesses/shared/pitch-context-selector.sh) — everyone else must declare a
# non-empty list.
#
# Usage: bash mode-context-parity_test.sh
# Exit 0 → all pass. Exit 1 → one or more failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CFG="$CODEGEN_DIR/templates/generator/config.yaml"

REQUIRED_MODES=(babysit ops debug)
EXEMPT_MODES=(shape experiment)
ALL_MODES=(babysit ops debug shape experiment)

pass=0
fail=0

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "0" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: $desc"
        fail=$((fail + 1))
    fi
}

# Test 1: required modes declare a non-empty context_files list.
for m in "${REQUIRED_MODES[@]}"; do
    n=$(yq -r ".roles.$m.context_files // [] | length" "$CFG")
    if [ "$n" -ge 1 ]; then
        assert_true "roles.$m.context_files is non-empty" 0
    else
        echo "  mode-context-parity: FAIL — roles.$m declares no context_files"
        assert_true "roles.$m.context_files is non-empty" 1
    fi
done

# Test 7: exempt modes declare context_files present-but-empty (never absent).
for m in "${EXEMPT_MODES[@]}"; do
    present=$(yq -r "(.roles.$m | has(\"context_files\"))" "$CFG")
    n=$(yq -r ".roles.$m.context_files // [\"__absent__\"] | length" "$CFG")
    if [ "$present" = "true" ] && [ "$n" -eq 0 ]; then
        assert_true "roles.$m.context_files is explicitly []" 0
    else
        echo "  mode-context-parity: FAIL — roles.$m.context_files must be present and []"
        assert_true "roles.$m.context_files is explicitly []" 1
    fi
done

# Test 2: every declared path exists under CODEGEN_DIR.
for m in "${ALL_MODES[@]}"; do
    paths=$(yq -r ".roles.$m.context_files // [] | .[]" "$CFG")
    missing=""
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -f "$CODEGEN_DIR/$p" ] || missing="${missing}${missing:+, }$p"
    done <<<"$paths"
    if [ -z "$missing" ]; then
        assert_true "roles.$m.context_files paths all exist" 0
    else
        echo "  mode-context-parity: FAIL — roles.$m declares missing path(s): $missing"
        assert_true "roles.$m.context_files paths all exist" 1
    fi
done

# Test 3: resolve_mode_context fails loud on a missing declared file.
tmp_cfg=$(mktemp)
trap 'rm -f "$tmp_cfg"' EXIT
yq '.roles.__scratch_mode__.context_files = ["context/__definitely_does_not_exist__.md"]' "$CFG" >"$tmp_cfg"

set +e
fail_output=$(
    CODEGEN_DIR="$CODEGEN_DIR" bash -c '
        _cfg="'"$tmp_cfg"'"
        _mode="__scratch_mode__"
        _files=$(yq -r ".roles.$_mode.context_files // [] | .[]" "$_cfg")
        while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            if [ ! -f "'"$CODEGEN_DIR"'/$_f" ]; then
                echo "resolve_mode_context: roles.$_mode.context_files declares $_f, not found at '"$CODEGEN_DIR"'/$_f" >&2
                exit 1
            fi
        done <<<"$_files"
    ' 2>&1
)
fail_rc=$?
set -e
if [ "$fail_rc" -eq 1 ] && echo "$fail_output" | grep -qF "__scratch_mode__" && echo "$fail_output" | grep -qF "context/__definitely_does_not_exist__.md"; then
    assert_true "resolve_mode_context fails loud on missing file (exit 1, names mode+path)" 0
else
    echo "  got rc=$fail_rc output=$fail_output"
    assert_true "resolve_mode_context fails loud on missing file (exit 1, names mode+path)" 1
fi

# Test 4/5/6/8/9: launcher consumption + ordering + no hand-rolled injection.
CLAUDE_LAUNCHERS=(claude-babysit.sh claude-ops.sh claude-debug.sh)
PI_LAUNCHERS=(pi-babysit.sh pi-ops.sh pi-debug.sh)

for f in "${CLAUDE_LAUNCHERS[@]}"; do
    path="$CODEGEN_DIR/harnesses/claude/$f"
    if grep -qF "ROLE_CONTEXT_FILES" "$path"; then
        assert_true "$f consumes ROLE_CONTEXT_FILES" 0
    else
        assert_true "$f consumes ROLE_CONTEXT_FILES" 1
    fi
done

for f in "${PI_LAUNCHERS[@]}"; do
    path="$CODEGEN_DIR/harnesses/pi/$f"
    ok=0
    grep -qF "resolve_mode_context" "$path" || ok=1
    grep -qF "ROLE_CONTEXT_FILES" "$path" || ok=1
    if [ "$ok" -eq 0 ]; then
        assert_true "$f consumes resolve_mode_context + ROLE_CONTEXT_FILES" 0
    else
        assert_true "$f consumes resolve_mode_context + ROLE_CONTEXT_FILES" 1
    fi
done

# Test 6: no hand-rolled injection remains in the 6 non-exempt launchers.
for f in "${CLAUDE_LAUNCHERS[@]}" "${PI_LAUNCHERS[@]}"; do
    case "$f" in
    claude-*) path="$CODEGEN_DIR/harnesses/claude/$f" ;;
    pi-*) path="$CODEGEN_DIR/harnesses/pi/$f" ;;
    esac
    if grep -qE '\-\-append-system-prompt "\$\(cat ' "$path" 2>/dev/null; then
        # Allowed only when the $(cat ...) reads a context_files entry, i.e.
        # the line also references $CODEGEN_DIR/$_cf (our own loop var).
        if grep -E '\-\-append-system-prompt "\$\(cat ' "$path" | grep -qvF '$CODEGEN_DIR/$_cf'; then
            assert_true "$f has no stray hand-rolled --append-system-prompt \$(cat ...)" 1
        else
            assert_true "$f has no stray hand-rolled --append-system-prompt \$(cat ...)" 0
        fi
    else
        assert_true "$f has no stray hand-rolled --append-system-prompt \$(cat ...)" 0
    fi
done

# Test 8: pi ordering — resolve_mode_context call precedes the mode's
# *_STARTUP concat.
startup_var_for() {
    case "$1" in
    pi-babysit.sh) echo BABYSIT_STARTUP ;;
    pi-ops.sh) echo OPS_CONTEXT ;;
    pi-debug.sh) echo DEBUG_CONTEXT ;;
    esac
}
for f in "${PI_LAUNCHERS[@]}"; do
    path="$CODEGEN_DIR/harnesses/pi/$f"
    rmc_line=$(grep -n "resolve_mode_context " "$path" | head -1 | cut -d: -f1)
    startup_var=$(startup_var_for "$f")
    startup_line=$(grep -n "^${startup_var}=" "$path" | head -1 | cut -d: -f1)
    if [ -n "$rmc_line" ] && [ -n "$startup_line" ] && [ "$rmc_line" -lt "$startup_line" ]; then
        assert_true "$f: resolve_mode_context precedes $startup_var assignment" 0
    else
        echo "  $f: rmc_line=$rmc_line startup_line=$startup_line"
        assert_true "$f: resolve_mode_context precedes $startup_var assignment" 1
    fi
done

# Test 9: syntax check.
for f in "$CODEGEN_DIR/harnesses/shared/mode-context.sh" \
    "${CLAUDE_LAUNCHERS[@]/#/$CODEGEN_DIR/harnesses/claude/}" \
    "${PI_LAUNCHERS[@]/#/$CODEGEN_DIR/harnesses/pi/}"; do
    if bash -n "$f" 2>/dev/null; then
        assert_true "$(basename "$f") passes bash -n" 0
    else
        assert_true "$(basename "$f") passes bash -n" 1
    fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
