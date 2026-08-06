#!/usr/bin/env bash
# denial-ledger-replay_test.sh — replays every row in
# fixtures/denial-ledger.jsonl through the LIVE PreToolUse hook set,
# composing first-deny-wins, and fails on any mismatch against the row's
# recorded `expect` (allow|deny).
#
# This is the Layer-4 recurrence obligation from the pitch "a guard denies
# only what the role must not do": a guard's allow set must be validated
# against the record of what roles actually ran, not against its author's
# imagination. The ledger is a curated extract of the incident's 63
# permission denials (see the pitch body for the full replay/attribution
# evidence) plus baseline regression rows proving defensible-policy denials
# stayed denied.
#
# Discovers hooks dynamically from claude-code-settings.json (mirrors
# mode-matrix_test.sh's proven pattern) so any NEW hook auto-participates —
# a false positive in a hook added after this test was written still turns
# `make test` red the moment a ledger row exercises it.
#
# Auto-discovered by run-tests.sh — no Makefile wiring required (see
# context/development.md § Make Targets, "auto-discovery scopes").

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$SCRIPT_DIR/fixtures/denial-ledger.jsonl"
SETTINGS="$SCRIPT_DIR/../claude-code-settings.json"

pass=0
fail=0

# Clean up any stale developer-no-self-gate.sh counter/signature files from
# a PRIOR run of this same test on this machine (session_id is derived from
# the ledger's own case names below, so a re-run reuses the same paths).
# Best-effort only — never fail the test over a cleanup miss.
rm -f /tmp/codegen-self-gate-ledger-replay-*.sig /tmp/codegen-self-gate-ledger-replay-*.count 2>/dev/null || true

if [ ! -f "$LEDGER" ]; then
    printf 'FAIL: denial ledger not found at %s\n' "$LEDGER"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ── Hook discovery: every PreToolUse (matcher, hook-basename) pair, resolved
# to the hook's in-repo source copy (never the installed ~/.claude/hooks/
# copy — this test must catch a regression BEFORE make install bakes it
# out). Real Claude Code only invokes a hook when its tool_name matches the
# hook's registered matcher — replaying EVERY hook against EVERY row
# regardless of matcher produces false denials from hooks that were never
# actually reachable for that tool (e.g. a Write|Edit-matcher hook fired on
# a Bash-tool_name row misreads an absent FILE_PATH as an anomaly). One line
# per pair, tab-separated: "<matcher>\t<basename>". ─────────────────────────
discover_pretooluse_pairs() {
    jq -r '.hooks.PreToolUse[] | . as $e | $e.hooks[].command | "\($e.matcher)\t\(. | sub(".*/";""))"' "$SETTINGS"
}

MATCHERS=()
BASENAMES=()
while IFS=$'\t' read -r matcher basename; do
    [ -z "$basename" ] && continue
    MATCHERS+=("$matcher")
    BASENAMES+=("$basename")
done < <(discover_pretooluse_pairs)

if [ "${#BASENAMES[@]}" -eq 0 ]; then
    printf 'FAIL: hook discovery returned zero hooks — settings.json unreadable or empty?\n'
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# matcher_includes_tool <matcher> <tool_name> — true when the pipe-delimited
# matcher string contains tool_name as an exact alternative (not a substring
# match — "Bash" must not match a hypothetical "BashFoo").
matcher_includes_tool() {
    local matcher="$1" tool="$2"
    local IFS='|'
    local -a alts=($matcher)
    local alt
    for alt in "${alts[@]}"; do
        [ "$alt" = "$tool" ] && return 0
    done
    return 1
}

# composed_verdict <payload_json> <env_json> <tool_name> — pipes payload
# through every discovered hook WHOSE MATCHER INCLUDES tool_name, in order;
# first "permissionDecision":"deny" wins. env_json (a flat string-valued
# object, or "{}"/null) is exported as extra env vars for hooks that key on
# CLAUDE_ROLE rather than the JSON payload (role-family hooks resolve role
# via _role.sh's resolve_role(), which reads CLAUDE_ROLE).
composed_verdict() {
    local payload="$1"
    local env_json="$2"
    local tool="$3"

    local env_args=()
    if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
        while IFS='=' read -r k v; do
            [ -z "$k" ] && continue
            env_args+=("$k=$v")
        done < <(printf '%s' "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
    fi

    local i
    for i in "${!BASENAMES[@]}"; do
        matcher_includes_tool "${MATCHERS[$i]}" "$tool" || continue
        local hook="$SCRIPT_DIR/${BASENAMES[$i]}"
        local out
        if [ "${#env_args[@]}" -gt 0 ]; then
            out=$(printf '%s' "$payload" | env "${env_args[@]}" bash "$hook" 2>/dev/null || true)
        else
            out=$(printf '%s' "$payload" | bash "$hook" 2>/dev/null || true)
        fi
        if printf '%s' "$out" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
            printf 'deny'
            return 0
        fi
    done
    printf 'allow'
}

# ── Replay every ledger row ──────────────────────────────────────────────
line_no=0
while IFS= read -r row; do
    line_no=$((line_no + 1))
    [ -z "${row// /}" ] && continue

    if ! printf '%s' "$row" | jq -e . >/dev/null 2>&1; then
        printf 'FAIL: ledger line %d is not valid JSON\n' "$line_no"
        fail=$((fail + 1))
        continue
    fi

    case_name=$(printf '%s' "$row" | jq -r '.case // empty')
    expect=$(printf '%s' "$row" | jq -r '.expect // empty')

    if [ -z "$case_name" ] || [ -z "$expect" ]; then
        printf 'FAIL: ledger line %d missing required field(s) case/expect\n' "$line_no"
        fail=$((fail + 1))
        continue
    fi
    case "$expect" in
    allow | deny) ;;
    *)
        printf 'FAIL: ledger case %s has invalid expect=%s (must be allow|deny)\n' "$case_name" "$expect"
        fail=$((fail + 1))
        continue
        ;;
    esac

    agent_type=$(printf '%s' "$row" | jq -r '.agent_type // ""')
    tool_name=$(printf '%s' "$row" | jq -r '.tool_name // empty')
    tool_input=$(printf '%s' "$row" | jq -c '.tool_input // {}')
    env_json=$(printf '%s' "$row" | jq -c '.env // {}')

    if [ -z "$tool_name" ]; then
        printf 'FAIL: ledger case %s missing required field tool_name\n' "$case_name"
        fail=$((fail + 1))
        continue
    fi

    # session_id is keyed to THIS ROW's case name, not a fixed constant —
    # developer-no-self-gate.sh persists a counter/signature to
    # /tmp/codegen-self-gate-${session_id}.{sig,count}, so a shared
    # session_id across rows lets an earlier gate-command row's counter leak
    # into a later, unrelated row (e.g. row N's mix-format case denies
    # because rows 1..N-1 already ran mix test/format/ci under the SAME
    # session_id and pushed the counter past the cap). A per-row unique id
    # isolates that persisted state exactly the way two real, unrelated
    # Claude sessions would never share a counter file.
    payload=$(jq -n \
        --arg tn "$tool_name" \
        --arg at "$agent_type" \
        --arg sid "ledger-replay-$case_name" \
        --argjson ti "$tool_input" \
        '{tool_name: $tn, agent_type: $at, tool_input: $ti, session_id: $sid, transcript_path: "", cwd: ""}')

    got=$(composed_verdict "$payload" "$env_json" "$tool_name")

    if [ "$got" = "$expect" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$case_name"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n' "$case_name" "$expect" "$got"
        fail=$((fail + 1))
    fi
done <"$LEDGER"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
