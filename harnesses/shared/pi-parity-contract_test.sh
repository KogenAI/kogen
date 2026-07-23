#!/usr/bin/env bash
# pi-parity-contract_test.sh — hermetic schema validator for
# harnesses/shared/pi-parity-ledger.yaml.
#
# Sub-slice 1 scope: SCHEMA + source-path-existence only. Does NOT check that
# every codegen-managed surface has a row (full surface discovery is a later
# slice) and does NOT check that probe test IDs resolve to real tests (probe
# IDs are validated as non-empty opaque strings only in this slice).
#
# Tests:
#   1. version == 1
#   2. every surface has all required keys (id, class, claude_source,
#      pi_source, authority, probe, status)
#   3. class is one of: launcher|mode|tool|command|policy|event|completion
#   4. authority is one of: structural|runtime|deterministic
#   5. status is one of: equivalent|vendor-divergence
#   6. no duplicate id across surfaces
#   7. every claude_source path exists on disk
#   8. every pi_source path exists on disk
#   9. probe.darwin/linux/failure are non-empty strings
#   10. malformed fixture (row missing a required key) fails validation
#
# Usage: bash pi-parity-contract_test.sh
# Exit 0 -> all pass. Exit 1 -> one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEDGER="$SCRIPT_DIR/pi-parity-ledger.yaml"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_true() {
    local desc="$1" cond="$2"
    if [ "$cond" = "0" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n' "$desc"
        fail=$((fail + 1))
    fi
}

# validate_ledger <ledger_path> <repo_root>
# Prints "OK" on stdout and exits 0 when the ledger is well-formed; prints a
# reason to stderr and exits 1 otherwise. Pure schema + path-existence check.
validate_ledger() {
    local ledger="$1"
    local root="$2"

    [ -f "$ledger" ] || {
        echo "ledger file not found: $ledger" >&2
        return 1
    }

    local version
    version=$(yq -r '.version' "$ledger" 2>/dev/null) || {
        echo "ledger did not parse as YAML" >&2
        return 1
    }
    [ "$version" = "1" ] || {
        echo "version != 1 (got: $version)" >&2
        return 1
    }

    local n
    n=$(yq -r '.surfaces | length' "$ledger" 2>/dev/null) || {
        echo "surfaces list missing or unparsable" >&2
        return 1
    }
    [ "$n" -gt 0 ] || {
        echo "surfaces list is empty" >&2
        return 1
    }

    local i
    local ids=""
    for ((i = 0; i < n; i++)); do
        local id class claude_source pi_source authority status probe_darwin probe_linux probe_failure
        id=$(yq -r ".surfaces[$i].id" "$ledger")
        class=$(yq -r ".surfaces[$i].class" "$ledger")
        claude_source=$(yq -r ".surfaces[$i].claude_source" "$ledger")
        pi_source=$(yq -r ".surfaces[$i].pi_source" "$ledger")
        authority=$(yq -r ".surfaces[$i].authority" "$ledger")
        status=$(yq -r ".surfaces[$i].status" "$ledger")
        probe_darwin=$(yq -r ".surfaces[$i].probe.darwin" "$ledger")
        probe_linux=$(yq -r ".surfaces[$i].probe.linux" "$ledger")
        probe_failure=$(yq -r ".surfaces[$i].probe.failure" "$ledger")

        for field_name in id class claude_source pi_source authority status probe_darwin probe_linux probe_failure; do
            local val="${!field_name}"
            if [ -z "$val" ] || [ "$val" = "null" ]; then
                echo "surface[$i] missing required key: $field_name" >&2
                return 1
            fi
        done

        case "$class" in
        launcher | mode | tool | command | policy | event | completion) ;;
        *)
            echo "surface[$i] ($id) has invalid class: $class" >&2
            return 1
            ;;
        esac

        case "$authority" in
        structural | runtime | deterministic) ;;
        *)
            echo "surface[$i] ($id) has invalid authority: $authority" >&2
            return 1
            ;;
        esac

        case "$status" in
        equivalent | vendor-divergence) ;;
        *)
            echo "surface[$i] ($id) has invalid status: $status" >&2
            return 1
            ;;
        esac

        case "$ids" in
        *"|$id|"*)
            echo "duplicate id: $id" >&2
            return 1
            ;;
        esac
        ids="${ids}|${id}|"

        if [ ! -e "$root/$claude_source" ]; then
            echo "surface[$i] ($id) claude_source does not exist: $claude_source" >&2
            return 1
        fi
        if [ ! -e "$root/$pi_source" ]; then
            echo "surface[$i] ($id) pi_source does not exist: $pi_source" >&2
            return 1
        fi
    done

    echo "OK"
    return 0
}

# ── Test 1-9: real ledger validates clean ────────────────────────────────────
out=$(validate_ledger "$LEDGER" "$CODEGEN_DIR" 2>&1)
rc=$?
assert_true "real ledger validates (schema + path existence)" "$rc"
assert_eq "real ledger validator prints OK" "OK" "$out"

version=$(yq -r '.version' "$LEDGER")
assert_eq "version == 1" "1" "$version"

n=$(yq -r '.surfaces | length' "$LEDGER")
assert_true "surfaces list non-empty" "$([ "$n" -gt 0 ] && echo 0 || echo 1)"

dup_ids=$(yq -r '.surfaces[].id' "$LEDGER" | sort | uniq -d)
assert_eq "no duplicate ids" "" "$dup_ids"

bad_class=$(yq -r '.surfaces[].class' "$LEDGER" | grep -Ev '^(launcher|mode|tool|command|policy|event|completion)$' || true)
assert_eq "all class values in enum" "" "$bad_class"

bad_authority=$(yq -r '.surfaces[].authority' "$LEDGER" | grep -Ev '^(structural|runtime|deterministic)$' || true)
assert_eq "all authority values in enum" "" "$bad_authority"

bad_status=$(yq -r '.surfaces[].status' "$LEDGER" | grep -Ev '^(equivalent|vendor-divergence)$' || true)
assert_eq "all status values in enum" "" "$bad_status"

# ── Test 10: malformed fixture (missing key) fails validation ────────────────
TMP_LEDGER=$(mktemp)
trap 'rm -f "$TMP_LEDGER"' EXIT
cat >"$TMP_LEDGER" <<'YAML'
version: 1
surfaces:
  - id: broken-surface
    class: launcher
    claude_source: harnesses/claude/claude-build.sh
    # pi_source deliberately missing
    authority: runtime
    probe: { darwin: T-x, linux: T-y, failure: T-z }
    status: equivalent
YAML
validate_ledger "$TMP_LEDGER" "$CODEGEN_DIR" >/dev/null 2>&1
rc=$?
assert_true "malformed fixture (missing pi_source) fails validation" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# ── Test 11: malformed fixture (nonexistent source path) fails validation ────
TMP_LEDGER2=$(mktemp)
cat >"$TMP_LEDGER2" <<'YAML'
version: 1
surfaces:
  - id: ghost-surface
    class: launcher
    claude_source: harnesses/claude/does-not-exist.sh
    pi_source: harnesses/pi/pi-build.sh
    authority: runtime
    probe: { darwin: T-x, linux: T-y, failure: T-z }
    status: equivalent
YAML
validate_ledger "$TMP_LEDGER2" "$CODEGEN_DIR" >/dev/null 2>&1
rc=$?
assert_true "malformed fixture (nonexistent source path) fails validation" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f "$TMP_LEDGER2"

# ── Test 12: malformed fixture (bad enum value) fails validation ─────────────
TMP_LEDGER3=$(mktemp)
cat >"$TMP_LEDGER3" <<'YAML'
version: 1
surfaces:
  - id: bad-enum-surface
    class: launcher
    claude_source: harnesses/claude/claude-build.sh
    pi_source: harnesses/pi/pi-build.sh
    authority: bogus-authority
    probe: { darwin: T-x, linux: T-y, failure: T-z }
    status: equivalent
YAML
validate_ledger "$TMP_LEDGER3" "$CODEGEN_DIR" >/dev/null 2>&1
rc=$?
assert_true "malformed fixture (bad authority enum) fails validation" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
rm -f "$TMP_LEDGER3"

echo "$pass passed, $fail failed"

[ "$fail" -eq 0 ]
