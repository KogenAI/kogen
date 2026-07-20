#!/usr/bin/env bash
# _waiver_test.sh — unit tests for _waiver.sh
#
# NOT a registered hook (helper library) — no HOOK-MANIFEST header required;
# exempt via hook_registrations.py's --exclude-pattern=_test.sh. Auto-
# discovered by run-tests.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

assert_true() {
    local desc="$1"
    shift
    if "$@"; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n' "$desc"
        fail=$((fail + 1))
    fi
}

assert_false() {
    local desc="$1"
    shift
    if "$@"; then
        printf 'FAIL: %s (expected false, got true)\n' "$desc"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

# Build an isolated fake repo root: registry.yaml (real-ish minimal fixture)
# + codegen/pitches/building/<slug>.md. Canonicalize via pwd -P (macOS
# /var -> /private/var symlink).
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/shared/enforcement"
mkdir -p "$TMP_ROOT/codegen/pitches/building"

cat >"$TMP_ROOT/shared/enforcement/registry.yaml" <<'EOF'
- kind: registration
  id: prompt-budget-writer-only
  event: PreToolUse
  tool_guard: "Bash|Edit|Write|MultiEdit"
  surface: user_global
  signal: AGENT_TYPE
  role: "*"
  harnesses: all
  waivable: true
  rationale: fixture entry

- kind: registration
  id: session-log-writer-only
  event: PreToolUse
  tool_guard: "Bash|Edit|Write|MultiEdit"
  surface: user_global
  signal: AGENT_TYPE
  role: "*"
  harnesses: all
EOF

# Inside a real git working tree, _waiver_repo_root() uses `git rev-parse
# --show-toplevel`; outside one it falls back to pwd -P. Run every case
# from inside TMP_ROOT with no .git present so the fallback resolves TMP_ROOT.
cd "$TMP_ROOT"

# stub codegen-log so _waiver_record's append call cannot fail the suite
# (it must succeed silently — a real codegen-log binary is not on PATH here).
STUB_BIN="$TMP_ROOT/stubbin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/codegen-log" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_BIN/codegen-log"
export PATH="$STUB_BIN:$PATH"

write_pitch() {
    local slug="$1" waives_line="$2"
    rm -rf "$TMP_ROOT/codegen/pitches/building"
    mkdir -p "$TMP_ROOT/codegen/pitches/building"
    {
        printf -- '---\n'
        printf 'status: ready\n'
        [ -n "$waives_line" ] && printf '%s\n' "$waives_line"
        printf -- '---\n'
        printf '# %s\n' "$slug"
    } >"$TMP_ROOT/codegen/pitches/building/$slug.md"
}

clear_pitches() {
    rm -rf "$TMP_ROOT/codegen/pitches/building"
    mkdir -p "$TMP_ROOT/codegen/pitches/building"
}

_run_waived() {
    local hook_id="$1"
    (
        # shellcheck source=/dev/null
        source "$WAIVER_SCRIPT_DIR/_role.sh"
        # shellcheck source=/dev/null
        source "$WAIVER_SCRIPT_DIR/_waiver.sh"
        waived? "$hook_id"
    )
}
export WAIVER_SCRIPT_DIR="$SCRIPT_DIR"

# ── (1) env + file both name id → waived? true ──
write_pitch "wtest1" "waives: [prompt-budget-writer-only]"
assert_true "env+file both name id -> waived" \
    env CODEGEN_WAIVED_GUARDS=prompt-budget-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

# ── (2) env only (file omits it) → deny ──
write_pitch "wtest2" ""
assert_false "env only, file omits -> deny" \
    env CODEGEN_WAIVED_GUARDS=prompt-budget-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

# ── (3) file only (env unset) → deny ──
write_pitch "wtest3" "waives: [prompt-budget-writer-only]"
assert_false "file only, env unset -> deny" \
    env -u CODEGEN_WAIVED_GUARDS bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

# ── (4) neither set / malformed → deny ──
clear_pitches
assert_false "neither env nor file -> deny" \
    env -u CODEGEN_WAIVED_GUARDS bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

write_pitch "wtest4" "waives: not-a-list-([{"
assert_false "malformed waives line -> deny" \
    env CODEGEN_WAIVED_GUARDS=prompt-budget-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

# ── (5) non-waivable id in registry → deny regardless of env+file ──
write_pitch "wtest5" "waives: [session-log-writer-only]"
assert_false "non-waivable registry entry -> deny even with env+file" \
    env CODEGEN_WAIVED_GUARDS=session-log-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived session-log-writer-only"

# ── (6) zero and 2+ files in building/ → deny ──
clear_pitches
assert_false "zero files in building/ -> deny" \
    env CODEGEN_WAIVED_GUARDS=prompt-budget-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

write_pitch "wtest6a" "waives: [prompt-budget-writer-only]"
{
    printf -- '---\n'
    printf 'status: ready\n'
    printf 'waives: [prompt-budget-writer-only]\n'
    printf -- '---\n'
    printf '# wtest6b\n'
} >"$TMP_ROOT/codegen/pitches/building/wtest6b.md"
assert_false "2+ files in building/ -> deny" \
    env CODEGEN_WAIVED_GUARDS=prompt-budget-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

# ── (7) waives: resolution unaffected by neighboring handoffs:/
# handoff_receipt: keys (compatibility fixture) ──
clear_pitches
write_pitch "wtest7" "$(printf 'waives: [prompt-budget-writer-only]\nhandoffs: [d::wtest7::other::lib/x.ex]\nhandoff_receipt: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
assert_true "waives: with neighboring handoffs: keys still resolves -> waived" \
    env CODEGEN_WAIVED_GUARDS=prompt-budget-writer-only bash -c "cd '$TMP_ROOT' && $(declare -f _run_waived); _run_waived prompt-budget-writer-only"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
