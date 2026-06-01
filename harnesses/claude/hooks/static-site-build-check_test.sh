#!/bin/bash
# static-site-build-check_test.sh — unit tests for static-site-build-check.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/static-site-build-check.sh"

pass=0
fail=0

# run_test <desc> <expected_outcome: block|allow> <input_json>
run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$HOOK" 2>/dev/null || true)

    local outcome="allow"
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        outcome="block"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Each test gets a fresh temp dir set up as a static-site working tree.
make_tmp_site() {
    local d
    d=$(mktemp -d)
    (
        cd "$d"
        # Minimal valid working tree.
        cat >package.json <<'JSON'
{
  "scripts": {
    "build": "echo built",
    "serve": "npm run build && python3 -u -m http.server --directory public 0"
  }
}
JSON
    )
    printf '%s' "$d"
}

# make_transcript <transcript_path> <log_path> — write synthetic JSONL
# recording a Write to <log_path>.
make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

input_for() {
    local cwd="$1"
    local agent_type="${2:-developer-html}"
    local stop_active="${3:-false}"
    local transcript_path="${4:-}"
    cat <<JSON
{"hook_event_name":"SubagentStop","agent_type":"$agent_type","agent_id":"abc","session_id":"s1","cwd":"$cwd","stop_hook_active":$stop_active,"transcript_path":"$transcript_path"}
JSON
}

# ── Test 1: stop_hook_active=true short-circuits ────────────────────────────
T1=$(make_tmp_site)
run_test "stop_hook_active=true short-circuits" "allow" "$(input_for "$T1" developer-html true)"
rm -rf "$T1"

# ── Test 2: non-static-site agent_type exits 0 ──────────────────────────────
T2=$(make_tmp_site)
run_test "non-static-site agent_type is no-op" "allow" "$(input_for "$T2" developer-phoenix-backend)"
rm -rf "$T2"

# ── Test 3: missing package.json (Hugo case) passes ─────────────────────────
T3=$(mktemp -d)
run_test "missing package.json (Hugo case) passes" "allow" "$(input_for "$T3")"
rm -rf "$T3"

# ── Test 4: npm run build non-zero blocks ───────────────────────────────────
T4=$(mktemp -d)
cat >"$T4/package.json" <<'JSON'
{
  "scripts": {
    "build": "exit 1",
    "serve": "npm run build && python3 -u -m http.server --directory public 0"
  }
}
JSON
run_test "npm run build failure blocks" "block" "$(input_for "$T4")"
rm -rf "$T4"

# ── Test 5: package.json missing scripts.build blocks ───────────────────────
T5=$(mktemp -d)
cat >"$T5/package.json" <<'JSON'
{
  "scripts": {
    "serve": "python3 -u -m http.server --directory public 0"
  }
}
JSON
run_test "missing scripts.build blocks" "block" "$(input_for "$T5")"
rm -rf "$T5"

# ── Test 5b: tooling-only package.json (no scripts key) passes ──────────────
T5B=$(mktemp -d)
cat >"$T5B/package.json" <<'JSON'
{
  "devDependencies": {
    "prettier": "^3.8.1"
  }
}
JSON
run_test "tooling-only package.json (no scripts) passes" "allow" "$(input_for "$T5B")"
rm -rf "$T5B"

# ── Test 6: package.json missing scripts.serve blocks ───────────────────────
T6=$(mktemp -d)
cat >"$T6/package.json" <<'JSON'
{
  "scripts": {
    "build": "echo built"
  }
}
JSON
run_test "missing scripts.serve blocks" "block" "$(input_for "$T6")"
rm -rf "$T6"

# ── Test 7: scripts.serve does not end with canonical string blocks ─────────
T7=$(mktemp -d)
cat >"$T7/package.json" <<'JSON'
{
  "scripts": {
    "build": "echo built",
    "serve": "vite preview"
  }
}
JSON
run_test "scripts.serve wrong tail blocks" "block" "$(input_for "$T7")"
rm -rf "$T7"

# ── Test 8: tailwind.config.js present blocks ───────────────────────────────
T8=$(make_tmp_site)
touch "$T8/tailwind.config.js"
run_test "tailwind.config.js present blocks" "block" "$(input_for "$T8")"
rm -rf "$T8"

# ── Test 9: postcss.config.js present blocks ────────────────────────────────
T9=$(make_tmp_site)
touch "$T9/postcss.config.js"
run_test "postcss.config.js present blocks" "block" "$(input_for "$T9")"
rm -rf "$T9"

# ── Test 10: @tailwind directive blocks ─────────────────────────────────────
T10=$(make_tmp_site)
mkdir -p "$T10/src"
printf '@tailwind base;\n' >"$T10/src/app.css"
run_test "@tailwind directive blocks" "block" "$(input_for "$T10")"
rm -rf "$T10"

# ── Test 11: all checks pass — appends SSV section ──────────────────────────
T11=$(make_tmp_site)
mkdir -p "$T11/public" "$T11/codegen/logging"
touch "$T11/public/app.css"
LOG="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
cat >"$LOG" <<'MD'
# Session Log

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |
MD
make_transcript "$T11/transcript.jsonl" "$LOG"
out=$(printf '%s' "$(input_for "$T11" developer-html false "$T11/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
if [ -z "$out" ] && grep -q '## static-site-verifier Section' "$LOG"; then
    printf 'PASS: %s\n' "all checks pass — SSV section appended"
    pass=$((pass + 1))
else
    printf 'FAIL: %s\n  stdout: %s\n  log: %s\n' \
        "all checks pass — SSV section appended" "$out" "$(cat "$LOG")"
    fail=$((fail + 1))
fi
rm -rf "$T11"

# ── Test 12: A+B regression — A's transcript, B's newer log on disk → A's log ─
# B's log has newer mtime; transcript only records A → SSV appended to A's log.
T12A=$(make_tmp_site)
T12B=$(make_tmp_site)
mkdir -p "$T12A/public" "$T12A/codegen/logging" "$T12B/codegen/logging"
touch "$T12A/public/app.css"
LOG_A="$T12A/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session_A.md"
cat >"$LOG_A" <<'MD'
# Session A
MD
sleep 1
LOG_B="$T12B/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session_B.md"
cat >"$LOG_B" <<'MD'
# Session B
MD
# A's transcript only records A's log.
make_transcript "$T12A/transcript.jsonl" "$LOG_A"
out=$(printf '%s' "$(input_for "$T12A" developer-html false "$T12A/transcript.jsonl")" | bash "$HOOK" 2>/dev/null || true)
if grep -q '## static-site-verifier Section' "$LOG_A" && ! grep -q '## static-site-verifier Section' "$LOG_B"; then
    printf 'PASS: A+B regression: SSV appended to A only\n'
    pass=$((pass + 1))
else
    printf 'FAIL: A+B regression: wrong log got SSV section\n  A: %s\n  B: %s\n' "$(cat "$LOG_A")" "$(cat "$LOG_B")"
    fail=$((fail + 1))
fi
rm -rf "$T12A" "$T12B"

# ── Render-check stub tests ──────────────────────────────────────────────────
# Override RENDER_CHECK_CMD with a stub that emits a controlled verdict.
# This avoids needing a real browser or running playwright in bash tests.

make_render_stub() {
    local verdict_to_emit="$1"
    local stub_path
    stub_path=$(mktemp)
    cat >"$stub_path" <<STUB
#!/usr/bin/env bash
printf 'RENDER_VERDICT=%s\n' '$verdict_to_emit'
STUB
    chmod +x "$stub_path"
    printf '%s' "$stub_path"
}

# ── Test 13: render PASS — all checks pass + render PASS appends SSV ────────
T13=$(make_tmp_site)
mkdir -p "$T13/public" "$T13/codegen/logging"
touch "$T13/public/app.css"
printf '<html><head><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T13/public/index.html"
LOG13="$T13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
cat >"$LOG13" <<'MD'
# Session
MD
make_transcript "$T13/transcript.jsonl" "$LOG13"
STUB13=$(make_render_stub "PASS")
out13=$(printf '%s' "$(input_for "$T13" developer-html false "$T13/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB13" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
if [ -z "$out13" ] && grep -q 'DOM non-empty' "$LOG13"; then
    printf 'PASS: %s\n' "render PASS — SSV section includes render summary"
    pass=$((pass + 1))
else
    printf 'FAIL: render PASS — SSV section includes render summary\n  stdout: %s\n  log: %s\n' \
        "$out13" "$(grep 'render:' "$LOG13" || echo '(no render: line)')"
    fail=$((fail + 1))
fi
rm -f "$STUB13"
rm -rf "$T13"

# ── Test 14: render FAIL empty-dom — blocks ─────────────────────────────────
T14=$(make_tmp_site)
mkdir -p "$T14/public"
touch "$T14/public/app.css"
printf '<html><head><link rel="stylesheet" href="app.css"></head><body></body></html>\n' \
    >"$T14/public/index.html"
STUB14=$(make_render_stub "FAIL:empty-dom")
out14=$(printf '%s' "$(input_for "$T14")" |
    RENDER_CHECK_CMD="$STUB14" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome14="allow"
printf '%s' "$out14" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome14="block"
if [ "$outcome14" = "block" ]; then
    printf 'PASS: %s\n' "render FAIL empty-dom blocks"
    pass=$((pass + 1))
else
    printf 'FAIL: render FAIL empty-dom blocks\n  stdout: %s\n' "$out14"
    fail=$((fail + 1))
fi
rm -f "$STUB14"
rm -rf "$T14"

# ── Test 15: render FAIL unstyled — blocks ──────────────────────────────────
T15=$(make_tmp_site)
mkdir -p "$T15/public"
touch "$T15/public/app.css"
printf '<html><head></head><body><p>hi</p></body></html>\n' >"$T15/public/index.html"
STUB15=$(make_render_stub "FAIL:unstyled")
out15=$(printf '%s' "$(input_for "$T15")" |
    RENDER_CHECK_CMD="$STUB15" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome15="allow"
printf '%s' "$out15" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome15="block"
if [ "$outcome15" = "block" ]; then
    printf 'PASS: %s\n' "render FAIL unstyled blocks"
    pass=$((pass + 1))
else
    printf 'FAIL: render FAIL unstyled blocks\n  stdout: %s\n' "$out15"
    fail=$((fail + 1))
fi
rm -f "$STUB15"
rm -rf "$T15"

# ── Test 16: render FAIL js-error — blocks ──────────────────────────────────
# Uses RENDER_CHECK_CMD stub to avoid requiring Chromium on the host. The env
# var is inherited by the subshell: `printf ... | RENDER_CHECK_CMD=stub bash "$HOOK"`.
T16=$(make_tmp_site)
mkdir -p "$T16/public"
cat >"$T16/public/app.css" <<'CSS'
body { margin: 0; font-family: sans-serif; }
CSS
printf '<html><head><link rel="stylesheet" href="app.css"></head><body><p>hi</p><script>throw new Error("intentional test error");</script></body></html>\n' \
    >"$T16/public/index.html"
STUB16=$(make_render_stub "FAIL:js-error:Error: intentional test error")
out16=$(printf '%s' "$(input_for "$T16")" |
    RENDER_CHECK_CMD="$STUB16" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome16="allow"
printf '%s' "$out16" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome16="block"
if [ "$outcome16" = "block" ]; then
    printf 'PASS: %s\n' "render FAIL js-error blocks"
    pass=$((pass + 1))
else
    printf 'FAIL: render FAIL js-error blocks\n  stdout: %s\n' "$out16"
    fail=$((fail + 1))
fi
rm -f "$STUB16"
rm -rf "$T16"

# ── Test 17: render INCONCLUSIVE browser-not-installed — non-fatal ───────────
T17=$(make_tmp_site)
mkdir -p "$T17/public" "$T17/codegen/logging"
touch "$T17/public/app.css"
printf '<html><head><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T17/public/index.html"
LOG17="$T17/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
printf '# Session\n' >"$LOG17"
make_transcript "$T17/transcript.jsonl" "$LOG17"
STUB17=$(make_render_stub "INCONCLUSIVE:browser-not-installed")
out17=$(printf '%s' "$(input_for "$T17" developer-html false "$T17/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB17" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome17="allow"
printf '%s' "$out17" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome17="block"
if [ "$outcome17" = "allow" ] && grep -q '## static-site-verifier Section' "$LOG17"; then
    printf 'PASS: %s\n' "render INCONCLUSIVE browser-not-installed non-fatal"
    pass=$((pass + 1))
else
    printf 'FAIL: render INCONCLUSIVE browser-not-installed non-fatal\n  outcome: %s\n  stdout: %s\n' \
        "$outcome17" "$out17"
    fail=$((fail + 1))
fi
rm -f "$STUB17"
rm -rf "$T17"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
