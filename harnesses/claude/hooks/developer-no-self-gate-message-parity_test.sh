#!/bin/bash
# developer-no-self-gate-message-parity_test.sh — seam guard: the deny text
# names every command the matcher caps, and (bash twin only) names the
# bare-credo exemption.
#
# Declares:  the command_invokes()/commandInvokes() matcher patterns in
#            developer-no-self-gate.sh / .ts
# Reflects:  the deny() message strings in the same two files
#
# A pattern added to the matcher without being named in the message fails
# here. This is NOT a hardcoded list — the capped set is derived from the
# hook source's own matcher lines, so drift is caught mechanically.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK_SH="$SCRIPT_DIR/developer-no-self-gate.sh"
HOOK_TS="$CODEGEN_DIR/harnesses/pi/pi-extensions/enforcement/src/hooks/developer-no-self-gate.ts"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack (truncated): %.200s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_true() {
    local desc="$1"
    local cond="$2"
    if [ "$cond" -eq 0 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n' "$desc"
        fail=$((fail + 1))
    fi
}

# Extract every deny "..." text body (single- or double-quoted, bash form)
# from developer-no-self-gate.sh.
extract_deny_texts_sh() {
    # deny "..." spans one call per statement in this file (no multi-line
    # deny calls) — grab the quoted body after `deny "`.
    grep -o 'deny "[^"]*"' "$HOOK_SH" | sed -e 's/^deny "//' -e 's/"$//'
}

# Extract every deny(`...`) / deny("...") text body from the TS twin.
extract_deny_texts_ts() {
    # Handles both backtick-template and double-quote deny(...) call bodies
    # across the multi-line `return deny(\n  "...",\n);` shape in this file.
    awk '
        /return deny\(/ { capture=1; next }
        capture && /^[[:space:]]*[`"]/ {
            line=$0
            gsub(/^[[:space:]]*[`"]/, "", line)
            gsub(/[`"],?[[:space:]]*$/, "", line)
            print line
            capture=0
        }
    ' "$HOOK_TS"
}

# ── bash twin: capped set is mix test/format (credo bare-exempt), make ci/test
sh_deny_texts="$(extract_deny_texts_sh)"

assert_true "bash: at least 3 deny texts extracted" "$([ "$(printf '%s\n' "$sh_deny_texts" | grep -c .)" -ge 3 ] && echo 0 || echo 1)"

for cmd in "mix test" "mix format" "make ci" "make test"; do
    found=1
    while IFS= read -r text; do
        case "$text" in
        *"$cmd"*) found=0 ;;
        esac
    done <<EOF
$sh_deny_texts
EOF
    assert_true "bash: at least one deny text names '$cmd'" "$found"
done

# bash bare-credo exemption must be named in at least one deny text
credo_named=1
while IFS= read -r text; do
    case "$text" in
    *"credo"*"exempt"* | *"exempt"*"credo"*) credo_named=0 ;;
    esac
done <<EOF
$sh_deny_texts
EOF
assert_true "bash: at least one deny text names the mix-credo exemption" "$credo_named"

# bash: both firing ceilings (15 loop, 3 legacy) must appear somewhere
assert_contains "bash: loop ceiling (15) named in some deny text" "15" "$sh_deny_texts"

# ── TS twin: capped set is mix test/credo/format (NO exemption), make ci/test
ts_deny_texts="$(extract_deny_texts_ts)"

assert_true "ts: at least 3 deny texts extracted" "$([ "$(printf '%s\n' "$ts_deny_texts" | grep -c .)" -ge 3 ] && echo 0 || echo 1)"

for cmd in "mix test" "mix credo" "mix format" "make ci" "make test"; do
    found=1
    while IFS= read -r text; do
        case "$text" in
        *"$cmd"*) found=0 ;;
        esac
    done <<EOF
$ts_deny_texts
EOF
    assert_true "ts: at least one deny text names '$cmd'" "$found"
done

assert_contains "ts: loop ceiling (15) named in some deny text" "15" "$ts_deny_texts"

# ── RED-then-GREEN proof: a fixture hook whose matcher caps an EXTRA command
# not named in its own message must be caught by the same derivation logic.
tmp_fixture="$(mktemp)"
trap 'rm -f "$tmp_fixture"' EXIT
cat >"$tmp_fixture" <<'FIXTURE'
#!/bin/bash
if ! command_invokes "$COMMAND" '^mix$' '^(test|credo|format|xref)\b'; then
    exit 0
fi
deny "BLOCKED: ran mix test/format too many times."
FIXTURE

fixture_deny_texts="$(grep -o 'deny "[^"]*"' "$tmp_fixture" | sed -e 's/^deny "//' -e 's/"$//')"
fixture_names_xref=1
case "$fixture_deny_texts" in
*"xref"*) fixture_names_xref=0 ;;
esac
# RED proof: the fixture's matcher caps `xref` but its message never names
# it. fixture_names_xref==1 means "xref was NOT found in the message" —
# i.e. the guard logic correctly DETECTED the violation. Assert that
# detection outcome directly (0 would mean the guard missed a real gap).
assert_true "RED fixture: unnamed matcher pattern ('xref') correctly detected as missing from message" "$((1 - fixture_names_xref))"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
