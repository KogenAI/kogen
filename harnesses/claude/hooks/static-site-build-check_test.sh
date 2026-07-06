#!/bin/bash
# static-site-build-check_test.sh — unit tests for static-site-build-check.sh
#
# Tests 28-39: SEO/AI-discoverability baseline invariant (Check 6b). Each case
# violates exactly one invariant with all others valid + a PASS render stub,
# so the SEO check is the sole blocker under test.

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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
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
        printf 'ci:\n\t@true\n' >Makefile
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
    local agent_type="${2:-developer-static}"
    local stop_active="${3:-false}"
    local transcript_path="${4:-}"
    cat <<JSON
{"hook_event_name":"SubagentStop","agent_type":"$agent_type","agent_id":"abc","session_id":"s1","cwd":"$cwd","stop_hook_active":$stop_active,"transcript_path":"$transcript_path"}
JSON
}

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

# make_seo_site <canonical_url> — a make_tmp_site with a valid SEO/AI-discoverability
# baseline in public/index.html + public/robots.txt. canonical_url substitutes into
# the canonical link, og:image, and ld+json url fields (default SITE_URL_PLACEHOLDER).
make_seo_site() {
    local url="${1:-SITE_URL_PLACEHOLDER}"
    local d
    d=$(make_tmp_site)
    mkdir -p "$d/public"
    cat >"$d/public/robots.txt" <<'ROBOTS'
User-agent: *
Allow: /
ROBOTS
    cat >"$d/public/index.html" <<HTML
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>Test Site</title>
    <meta name="description" content="Test Site is a website." />
    <meta property="og:title" content="Test Site" />
    <meta property="og:description" content="Test Site is a website." />
    <meta property="og:type" content="website" />
    <meta property="og:image" content="https://${url}/og-image.png" />
    <link rel="canonical" href="https://${url}/" />
    <link rel="stylesheet" href="app.css" />
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "Test Site",
        "url": "https://${url}/"
      }
    </script>
  </head>
  <body>
    <p>hi</p>
  </body>
</html>
HTML
    touch "$d/public/app.css"
    printf '%s' "$d"
}

# ── Test 1: stop_hook_active=true short-circuits ────────────────────────────
T1=$(make_tmp_site)
run_test "stop_hook_active=true short-circuits" "allow" "$(input_for "$T1" developer-static true)"
rm -rf "$T1"

# ── Test 2: non-static-site agent_type exits 0 ──────────────────────────────
T2=$(make_tmp_site)
run_test "non-static-site agent_type is no-op" "allow" "$(input_for "$T2" developer-phoenix-backend)"
rm -rf "$T2"

# ── Test 3: missing package.json blocks (Vite always requires package.json) ──
T3=$(mktemp -d)
run_test "missing package.json blocks (Vite requires it)" "block" "$(input_for "$T3")"
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
printf 'ci:\n\texit 1\n' >"$T4/Makefile"
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
printf 'ci:\n\t@true\n' >"$T6/Makefile"
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
printf 'ci:\n\t@true\n' >"$T7/Makefile"
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
printf 'User-agent: *\nAllow: /\n' >"$T11/public/robots.txt"
printf 'body { font-family: sans-serif; }\n' >"$T11/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T11/public/index.html"
LOG="$T11/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG" <<'MD'
# Session Log

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |
MD
make_transcript "$T11/transcript.jsonl" "$LOG"
STUB11=$(make_render_stub "PASS")
out=$(printf '%s' "$(input_for "$T11" developer-static false "$T11/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB11" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
rm -f "$STUB11"
if [ -z "$out" ] && grep -q '## static-site-verifier Section' "$LOG"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "all checks pass — SSV section appended"
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
printf 'User-agent: *\nAllow: /\n' >"$T12A/public/robots.txt"
printf 'body { font-family: sans-serif; }\n' >"$T12A/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T12A/public/index.html"
LOG_A="$T12A/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_a_cycle.jsonl"
cat >"$LOG_A" <<'MD'
# Session A
MD
sleep 1
LOG_B="$T12B/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_b_cycle.jsonl"
cat >"$LOG_B" <<'MD'
# Session B
MD
# A's transcript only records A's log.
make_transcript "$T12A/transcript.jsonl" "$LOG_A"
STUB12=$(make_render_stub "PASS")
out=$(printf '%s' "$(input_for "$T12A" developer-static false "$T12A/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB12" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
rm -f "$STUB12"
if grep -q '## static-site-verifier Section' "$LOG_A" && ! grep -q '## static-site-verifier Section' "$LOG_B"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: A+B regression: SSV appended to A only\n'
    pass=$((pass + 1))
else
    printf 'FAIL: A+B regression: wrong log got SSV section\n  A: %s\n  B: %s\n' "$(cat "$LOG_A")" "$(cat "$LOG_B")"
    fail=$((fail + 1))
fi
rm -rf "$T12A" "$T12B"

# ── Render-check stub tests ──────────────────────────────────────────────────
# Override RENDER_CHECK_CMD with a stub that emits a controlled verdict.
# This avoids needing a real browser or running playwright in bash tests.
# (make_render_stub defined with helper functions above)

# ── Test 13: render PASS — all checks pass + render PASS appends SSV ────────
T13=$(make_tmp_site)
mkdir -p "$T13/public" "$T13/codegen/logging"
printf 'User-agent: *\nAllow: /\n' >"$T13/public/robots.txt"
touch "$T13/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T13/public/index.html"
LOG13="$T13/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG13" <<'MD'
# Session
MD
make_transcript "$T13/transcript.jsonl" "$LOG13"
STUB13=$(make_render_stub "PASS")
out13=$(printf '%s' "$(input_for "$T13" developer-static false "$T13/transcript.jsonl")" |
    RENDER_CHECK_CMD="$STUB13" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
if [ -z "$out13" ] && grep -q 'DOM non-empty' "$LOG13"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render PASS — SSV section includes render summary"
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
printf 'User-agent: *\nAllow: /\n' >"$T14/public/robots.txt"
touch "$T14/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body></body></html>\n' \
    >"$T14/public/index.html"
STUB14=$(make_render_stub "FAIL:empty-dom")
out14=$(printf '%s' "$(input_for "$T14")" |
    RENDER_CHECK_CMD="$STUB14" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome14="allow"
printf '%s' "$out14" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome14="block"
if [ "$outcome14" = "block" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render FAIL empty-dom blocks"
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
printf 'User-agent: *\nAllow: /\n' >"$T15/public/robots.txt"
touch "$T15/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script></head><body><p>hi</p></body></html>\n' >"$T15/public/index.html"
STUB15=$(make_render_stub "FAIL:unstyled")
out15=$(printf '%s' "$(input_for "$T15")" |
    RENDER_CHECK_CMD="$STUB15" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome15="allow"
printf '%s' "$out15" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome15="block"
if [ "$outcome15" = "block" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render FAIL unstyled blocks"
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
printf 'User-agent: *\nAllow: /\n' >"$T16/public/robots.txt"
cat >"$T16/public/app.css" <<'CSS'
body { margin: 0; font-family: sans-serif; }
CSS
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p><script>throw new Error("intentional test error");</script></body></html>\n' \
    >"$T16/public/index.html"
STUB16=$(make_render_stub "FAIL:js-error:Error: intentional test error")
out16=$(printf '%s' "$(input_for "$T16")" |
    RENDER_CHECK_CMD="$STUB16" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome16="allow"
printf '%s' "$out16" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome16="block"
if [ "$outcome16" = "block" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render FAIL js-error blocks"
    pass=$((pass + 1))
else
    printf 'FAIL: render FAIL js-error blocks\n  stdout: %s\n' "$out16"
    fail=$((fail + 1))
fi
rm -f "$STUB16"
rm -rf "$T16"

# ── Test 17: render INCONCLUSIVE chromium-launch-failed — BLOCKS (fail-closed) ─
# Gate must block when Chromium is absent; install guarantees it on static boxes.
T17=$(make_tmp_site)
mkdir -p "$T17/public"
printf 'User-agent: *\nAllow: /\n' >"$T17/public/robots.txt"
touch "$T17/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T17/public/index.html"
STUB17=$(make_render_stub "INCONCLUSIVE:chromium-launch-failed")
out17=$(printf '%s' "$(input_for "$T17")" |
    RENDER_CHECK_CMD="$STUB17" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome17="allow"
printf '%s' "$out17" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome17="block"
if [ "$outcome17" = "block" ] && printf '%s' "$out17" | grep -qi 'chromium\|browser'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render INCONCLUSIVE chromium-launch-failed blocks with browser message"
    pass=$((pass + 1))
else
    printf 'FAIL: render INCONCLUSIVE chromium-launch-failed should block with browser message\n  outcome: %s\n  stdout: %s\n' \
        "$outcome17" "$out17"
    fail=$((fail + 1))
fi
rm -f "$STUB17"
rm -rf "$T17"

# ── Test 18: render-check emitted no verdict (crash/parse error) — BLOCKS ─────
# When render-check.js crashes (e.g., SyntaxError, unhandled exception) it emits
# no RENDER_VERDICT= line. The gate must block with a clear error, not silently pass.
T18=$(make_tmp_site)
mkdir -p "$T18/public"
printf 'User-agent: *\nAllow: /\n' >"$T18/public/robots.txt"
touch "$T18/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T18/public/index.html"
# Stub outputs garbage (no RENDER_VERDICT= line) — simulates render-check.js crash
STUB18=$(mktemp)
cat >"$STUB18" <<'STUB'
#!/usr/bin/env bash
printf 'SyntaxError: some garbage output from a crashed render-check\n'
STUB
chmod +x "$STUB18"
out18=$(printf '%s' "$(input_for "$T18")" |
    RENDER_CHECK_CMD="$STUB18" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome18="allow"
printf '%s' "$out18" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome18="block"
if [ "$outcome18" = "block" ] && printf '%s' "$out18" | grep -q 'render-check did not emit verdict'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render-check crash (no verdict) blocks"
    pass=$((pass + 1))
else
    printf 'FAIL: render-check crash (no verdict) should block with no-verdict message\n  outcome: %s\n  stdout: %s\n' \
        "$outcome18" "$out18"
    fail=$((fail + 1))
fi
rm -f "$STUB18"
rm -rf "$T18"

# ── Test 19: GATED/clear stamp written when build passes (PASS render) ───────
T19=$(make_tmp_site)
mkdir -p "$T19/public"
printf 'User-agent: *\nAllow: /\n' >"$T19/public/robots.txt"
touch "$T19/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T19/public/index.html"
STUB19=$(mktemp)
cat >"$STUB19" <<'STUB'
#!/usr/bin/env bash
printf 'RENDER_VERDICT=PASS\n'
STUB
chmod +x "$STUB19"
printf '%s' "$(input_for "$T19")" |
    RENDER_CHECK_CMD="$STUB19" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true
cs_state19=""
cs_verdict19=""
cs_file19="$T19/codegen/gate-pending/cycle-state.json"
if [ -f "$cs_file19" ]; then
    cs_state19=$(jq -r '.state // ""' "$cs_file19" 2>/dev/null || printf '')
    cs_verdict19=$(jq -r '.verdict // ""' "$cs_file19" 2>/dev/null || printf '')
fi
if [ "$cs_state19" = "GATED" ] && [ "$cs_verdict19" = "clear" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: build+render PASS stamps GATED/clear in cycle-state.json\n'
    pass=$((pass + 1))
else
    printf 'FAIL: build+render PASS — expected state=GATED verdict=clear, got state=%s verdict=%s\n' \
        "$cs_state19" "$cs_verdict19"
    fail=$((fail + 1))
fi
rm -f "$STUB19"
rm -rf "$T19"

# ── Test 20: no cycle-state stamp on block (missing package.json) ─────────────
T20=$(mktemp -d)
# No package.json → block (not stamp); cycle-state.json should not be written
printf '%s' "$(input_for "$T20" developer-static)" |
    CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true
cs_file20="$T20/codegen/gate-pending/cycle-state.json"
if [ ! -f "$cs_file20" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: block (no package.json) → no cycle-state stamp\n'
    pass=$((pass + 1))
else
    cs_state20=$(jq -r '.state // ""' "$cs_file20" 2>/dev/null || printf '')
    printf 'FAIL: block path should NOT stamp cycle-state.json, but found state=%s\n' "$cs_state20"
    fail=$((fail + 1))
fi
rm -rf "$T20"

# ── Test 21: flat-layout — sibling render-check.js PASS stub ─────────────────
# Proves that the hook resolves render-check.js sibling-relative (BASH_SOURCE[0])
# WITHOUT needing CODEGEN_DIR at all. Copy hook + all lib/* into a temp dir so
# <tmp>/static-site-build-check.sh and <tmp>/lib/... are siblings, plant a
# PASS stub at <tmp>/lib/render-check.js, run the copied hook with CODEGEN_DIR
# unset and no RENDER_CHECK_CMD — should allow with no verdict error.
T21_FLAT=$(mktemp -d)
mkdir -p "$T21_FLAT/lib"
cp "$HOOK" "$T21_FLAT/"
cp "$SCRIPT_DIR"/lib/*.sh "$T21_FLAT/lib/"
cp "$SCRIPT_DIR/lib/gate-result.sh" "$T21_FLAT/lib/"
# Plant PASS stub as the sibling render-check.js
cat >"$T21_FLAT/lib/render-check.js" <<'JS'
process.stdout.write('RENDER_VERDICT=PASS\n');
JS
T21=$(make_tmp_site)
mkdir -p "$T21/public" "$T21/codegen/logging"
printf 'User-agent: *\nAllow: /\n' >"$T21/public/robots.txt"
touch "$T21/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T21/public/index.html"
LOG21="$T21/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_test_cycle.jsonl"
cat >"$LOG21" <<'MD'
# Session Log

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |
MD
make_transcript "$T21/transcript.jsonl" "$LOG21"
out21=$(printf '%s' "$(input_for "$T21" developer-static false "$T21/transcript.jsonl")" |
    env -u RENDER_CHECK_CMD -u CODEGEN_DIR bash "$T21_FLAT/static-site-build-check.sh" 2>/dev/null || true)
# Sibling lib/render-check.js is the PASS stub → should allow, no verdict error.
outcome21="allow"
printf '%s' "$out21" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome21="block"
if [ "$outcome21" = "allow" ] && ! grep -q 'render-check did not emit verdict' "$LOG21" 2>/dev/null; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "flat-layout sibling render-check.js PASS allows"
    pass=$((pass + 1))
else
    printf 'FAIL: flat-layout sibling render-check.js PASS — expected allow, got %s\n  stdout: %s\n  log: %s\n' \
        "$outcome21" "$out21" "$(cat "$LOG21" 2>/dev/null || echo '(no log)')"
    fail=$((fail + 1))
fi
rm -rf "$T21_FLAT" "$T21"

# ── Test 22: flat-layout — sibling render-check.js ABSENT → fail-loud ─────────
# When the hook runs outside the repo and lib/render-check.js is missing from the
# sibling lib/ dir, the preflight check must block with a clear path/install error.
T22_FLAT=$(mktemp -d)
mkdir -p "$T22_FLAT/lib"
cp "$HOOK" "$T22_FLAT/"
cp "$SCRIPT_DIR"/lib/*.sh "$T22_FLAT/lib/"
# Do NOT plant render-check.js — sibling is absent
T22=$(make_tmp_site)
mkdir -p "$T22/public"
printf 'User-agent: *\nAllow: /\n' >"$T22/public/robots.txt"
touch "$T22/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T22/public/index.html"
out22=$(printf '%s' "$(input_for "$T22" developer-static false)" |
    env -u RENDER_CHECK_CMD -u CODEGEN_DIR bash "$T22_FLAT/static-site-build-check.sh" 2>/dev/null || true)
outcome22="allow"
printf '%s' "$out22" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome22="block"
if [ "$outcome22" = "block" ] && printf '%s' "$out22" | grep -q 'render-check.js not found'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "flat-layout absent sibling render-check.js blocks with path error"
    pass=$((pass + 1))
else
    printf 'FAIL: flat-layout absent sibling render-check.js — expected block with path error, got %s\n  stdout: %s\n' \
        "$outcome22" "$out22"
    fail=$((fail + 1))
fi
rm -rf "$T22_FLAT" "$T22"

# ── Test 23: RENDER_CHECK_CMD emits playwright-module-unresolvable → BLOCKS ────
# When render-check.js cannot require playwright from any candidate, it emits
# INCONCLUSIVE:playwright-module-unresolvable. The static gate must BLOCK with a
# distinct loud message naming the path/env fault (not a browser message).
T23=$(make_tmp_site)
mkdir -p "$T23/public"
printf 'User-agent: *\nAllow: /\n' >"$T23/public/robots.txt"
touch "$T23/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T23/public/index.html"
STUB23=$(make_render_stub "INCONCLUSIVE:playwright-module-unresolvable")
out23=$(printf '%s' "$(input_for "$T23")" |
    RENDER_CHECK_CMD="$STUB23" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome23="allow"
printf '%s' "$out23" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome23="block"
if [ "$outcome23" = "block" ] && printf '%s' "$out23" | grep -qi 'playwright'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render INCONCLUSIVE playwright-module-unresolvable blocks with playwright message"
    pass=$((pass + 1))
else
    printf 'FAIL: render INCONCLUSIVE playwright-module-unresolvable should block with playwright message\n  outcome: %s\n  stdout: %s\n' \
        "$outcome23" "$out23"
    fail=$((fail + 1))
fi
rm -f "$STUB23"
rm -rf "$T23"

# ── Test 24: render-check stderr surfaced in block message ────────────────────
# A stub that prints to stderr and exits 1 (no RENDER_VERDICT= line).
# The gate must block AND the block message must contain the stderr marker.
T24=$(make_tmp_site)
mkdir -p "$T24/public"
printf 'User-agent: *\nAllow: /\n' >"$T24/public/robots.txt"
touch "$T24/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T24/public/index.html"
STUB24=$(mktemp)
cat >"$STUB24" <<'STUB'
#!/usr/bin/env bash
printf '__RC_STDERR_MARKER__\n' >&2
exit 1
STUB
chmod +x "$STUB24"
out24=$(printf '%s' "$(input_for "$T24")" |
    RENDER_CHECK_CMD="$STUB24" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome24="allow"
printf '%s' "$out24" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome24="block"
if [ "$outcome24" = "block" ] && printf '%s' "$out24" | grep -q '__RC_STDERR_MARKER__'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render-check stderr surfaced in block message"
    pass=$((pass + 1))
else
    printf 'FAIL: render-check stderr must appear in block message\n  outcome: %s\n  stdout: %s\n' \
        "$outcome24" "$out24"
    fail=$((fail + 1))
fi
rm -f "$STUB24"
rm -rf "$T24"

# ── Test 25: render INCONCLUSIVE config-error — BLOCKS (fail-closed) ─────────
# Generic INCONCLUSIVE:*) catch-all (config-error/timeout/server-unready) is
# no longer a silent pass-through — the gate cannot confirm a clean render,
# so it must block under the fail-closed-everywhere ruling.
T25=$(make_tmp_site)
mkdir -p "$T25/public"
printf 'User-agent: *\nAllow: /\n' >"$T25/public/robots.txt"
touch "$T25/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T25/public/index.html"
STUB25=$(make_render_stub "INCONCLUSIVE:config-error")
out25=$(printf '%s' "$(input_for "$T25")" |
    RENDER_CHECK_CMD="$STUB25" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome25="allow"
printf '%s' "$out25" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome25="block"
if [ "$outcome25" = "block" ] && printf '%s' "$out25" | grep -q 'config-error'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render INCONCLUSIVE config-error blocks (fail-closed)"
    pass=$((pass + 1))
else
    printf 'FAIL: render INCONCLUSIVE config-error should block (fail-closed)\n  outcome: %s\n  stdout: %s\n' \
        "$outcome25" "$out25"
    fail=$((fail + 1))
fi
rm -f "$STUB25"
rm -rf "$T25"

# ── Test 26: render INCONCLUSIVE timeout — BLOCKS (fail-closed) ─────────────
T26=$(make_tmp_site)
mkdir -p "$T26/public"
printf 'User-agent: *\nAllow: /\n' >"$T26/public/robots.txt"
touch "$T26/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T26/public/index.html"
STUB26=$(make_render_stub "INCONCLUSIVE:timeout")
out26=$(printf '%s' "$(input_for "$T26")" |
    RENDER_CHECK_CMD="$STUB26" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome26="allow"
printf '%s' "$out26" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome26="block"
if [ "$outcome26" = "block" ] && printf '%s' "$out26" | grep -q 'timeout'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render INCONCLUSIVE timeout blocks (fail-closed)"
    pass=$((pass + 1))
else
    printf 'FAIL: render INCONCLUSIVE timeout should block (fail-closed)\n  outcome: %s\n  stdout: %s\n' \
        "$outcome26" "$out26"
    fail=$((fail + 1))
fi
rm -f "$STUB26"
rm -rf "$T26"

# ── Test 27: render INCONCLUSIVE server-unready — BLOCKS (fail-closed) ──────
T27=$(make_tmp_site)
mkdir -p "$T27/public"
printf 'User-agent: *\nAllow: /\n' >"$T27/public/robots.txt"
touch "$T27/public/app.css"
printf '<html><head><meta name="description" content="Test Site is a website." /><meta property="og:title" content="Test Site" /><meta property="og:description" content="Test Site is a website." /><meta property="og:type" content="website" /><meta property="og:image" content="https://SITE_URL_PLACEHOLDER/og-image.png" /><link rel="canonical" href="https://SITE_URL_PLACEHOLDER/" /><script type="application/ld+json">{"@context":"https://schema.org","@type":"WebSite","name":"Test Site","url":"https://SITE_URL_PLACEHOLDER/"}</script><link rel="stylesheet" href="app.css"></head><body><p>hi</p></body></html>\n' \
    >"$T27/public/index.html"
STUB27=$(make_render_stub "INCONCLUSIVE:server-unready")
out27=$(printf '%s' "$(input_for "$T27")" |
    RENDER_CHECK_CMD="$STUB27" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
outcome27="allow"
printf '%s' "$out27" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome27="block"
if [ "$outcome27" = "block" ] && printf '%s' "$out27" | grep -q 'server-unready'; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "render INCONCLUSIVE server-unready blocks (fail-closed)"
    pass=$((pass + 1))
else
    printf 'FAIL: render INCONCLUSIVE server-unready should block (fail-closed)\n  outcome: %s\n  stdout: %s\n' \
        "$outcome27" "$out27"
    fail=$((fail + 1))
fi
rm -f "$STUB27"
rm -rf "$T27"

# ── SEO/AI-discoverability baseline tests ────────────────────────────────────
# Each case mutates make_seo_site's output to violate exactly ONE invariant
# (all others valid) with a PASS render stub, so the SEO check is the sole
# blocker under test. run_seo_test wires the PASS stub + CODEGEN_DIR uniformly.
run_seo_test() {
    local desc="$1"
    local expected="$2"
    local site_dir="$3"
    local stub
    stub=$(make_render_stub "PASS")
    local out
    out=$(printf '%s' "$(input_for "$site_dir")" |
        RENDER_CHECK_CMD="$stub" CODEGEN_DIR="$SCRIPT_DIR" bash "$HOOK" 2>/dev/null || true)
    rm -f "$stub"
    local outcome="allow"
    printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' && outcome="block"
    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$out"
        fail=$((fail + 1))
    fi
    rm -rf "$site_dir"
}

# ── Test 28: valid baseline with SITE_URL_PLACEHOLDER token — passes ────────
T28=$(make_seo_site "SITE_URL_PLACEHOLDER")
run_seo_test "SEO baseline: valid site with SITE_URL_PLACEHOLDER token passes" "allow" "$T28"

# ── Test 29: valid baseline with a real non-example.com URL — passes ────────
T29=$(make_seo_site "myrealsite.com")
run_seo_test "SEO baseline: valid site with real non-example.com URL passes" "allow" "$T29"

# ── Test 30: missing description — blocks ───────────────────────────────────
T30=$(make_seo_site)
python3 -c "
import re
p = '$T30/public/index.html'
c = open(p).read()
c = re.sub(r'\s*<meta name=\"description\"[^>]*/>\n', '\n', c)
open(p, 'w').write(c)
"
run_seo_test "SEO baseline: missing description blocks" "block" "$T30"

# ── Test 31: missing og:image — blocks ──────────────────────────────────────
T31=$(make_seo_site)
python3 -c "
import re
p = '$T31/public/index.html'
c = open(p).read()
c = re.sub(r'\s*<meta property=\"og:image\"[^>]*/>\n', '\n', c)
open(p, 'w').write(c)
"
run_seo_test "SEO baseline: missing og:image blocks" "block" "$T31"

# ── Test 32: missing canonical — blocks ──────────────────────────────────────
T32=$(make_seo_site)
python3 -c "
import re
p = '$T32/public/index.html'
c = open(p).read()
c = re.sub(r'\s*<link rel=\"canonical\"[^>]*/>\n', '\n', c)
open(p, 'w').write(c)
"
run_seo_test "SEO baseline: missing canonical blocks" "block" "$T32"

# ── Test 33: zero ld+json blocks — blocks ────────────────────────────────────
T33=$(make_seo_site)
python3 -c "
import re
p = '$T33/public/index.html'
c = open(p).read()
c = re.sub(r'\s*<script type=\"application/ld\+json\">.*?</script>\n', '\n', c, flags=re.DOTALL)
open(p, 'w').write(c)
"
run_seo_test "SEO baseline: zero ld+json blocks blocks" "block" "$T33"

# ── Test 34: two ld+json blocks — blocks ─────────────────────────────────────
T34=$(make_seo_site)
python3 -c "
p = '$T34/public/index.html'
c = open(p).read()
extra = '''    <script type=\"application/ld+json\">
      { \"@context\": \"https://schema.org\", \"@type\": \"WebSite\", \"name\": \"x\", \"url\": \"https://SITE_URL_PLACEHOLDER/\" }
    </script>
'''
c = c.replace('  </head>', extra + '  </head>')
open(p, 'w').write(c)
"
run_seo_test "SEO baseline: two ld+json blocks blocks" "block" "$T34"

# ── Test 35: malformed ld+json — blocks ──────────────────────────────────────
T35=$(make_seo_site)
python3 -c "
p = '$T35/public/index.html'
c = open(p).read()
c = c.replace('\"@type\": \"WebSite\",', '\"@type\" \"WebSite\"')
open(p, 'w').write(c)
"
run_seo_test "SEO baseline: malformed ld+json blocks" "block" "$T35"

# ── Test 36: missing public/robots.txt — blocks ──────────────────────────────
T36=$(make_seo_site)
rm -f "$T36/public/robots.txt"
run_seo_test "SEO baseline: missing public/robots.txt blocks" "block" "$T36"

# ── Test 37: example.com canonical — blocks ──────────────────────────────────
T37=$(make_seo_site "example.com")
run_seo_test "SEO baseline: example.com canonical blocks" "block" "$T37"

# ── Test 38: trav.example.com subdomain og:url-style — blocks ───────────────
T38=$(make_seo_site "trav.example.com")
run_seo_test "SEO baseline: trav.example.com subdomain blocks" "block" "$T38"

# ── Test 39: unreplaced %SITE% template variable — blocks ───────────────────
T39=$(make_seo_site "%SITE%")
run_seo_test "SEO baseline: unreplaced %SITE% template var blocks" "block" "$T39"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
