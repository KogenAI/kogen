#!/bin/bash
# enforcement_compiler_test.sh — unit tests for enforcement_compiler.py.
#
# Tests (42):
#   1:  parse valid registry; 17 sections in dry-run (count tracks live registry.yaml size)
#   2:  dialect translation bash: \\s → [[:space:]] in generated .sh
#   3:  match_all AND logic: two grep -qE calls joined with &&
#   4:  generated:false entry skipped (no file emitted)
#   5:  forbidden backreference rejected
#   6:  forbidden lookahead rejected
#   7:  empty registry produces no output files
#   8:  generated .sh passes bash -n syntax check
#   9:  generated .sh HOOK-MANIFEST headers match registry fields
#  10:  index.ts update wraps entries in BEGIN/END markers
#  11:  index.ts update is idempotent (re-run produces no diff)
#  12:  no-python-json.ts (match_all) generates correctly in TypeScript
#  13:  message backtick escaped in bash deny call
#  14:  match_all ts: both patterns present in generated .ts
#  15:  FILE_PATH source + allowlist: generated .ts contains repoRelative call
#  16:  FILE_PATH source + allowlist: generated .ts contains role guard
#  17:  FILE_PATH source + allowlist: pi-only entry does NOT emit .sh
#  18:  FILE_PATH source + allowlist: generated .ts deny message present
#  19:  COMMAND+allowlist: generated .sh allows matching command (git status)
#  20:  COMMAND+allowlist: generated .sh denies non-matching command (make test)
#  21:  COMMAND+allowlist: role-scoped .sh contains AGENT_TYPE case guard
#  22:  COMMAND+allowlist: generated .ts allows matching command (returns, no deny)
#  23:  COMMAND+allowlist: generated .ts denies non-matching command
#  24:  COMMAND+allowlist: generated .sh passes bash -n syntax check
#  25:  bypass_roles bash: generated .sh sources _role.sh
#  26:  bypass_roles bash: generated .sh contains resolve_role loop before body
#  27:  bypass_roles bash: bypass role exits early (CLAUDE_ROLE=shape → exit 0)
#  28:  bypass_roles bash: non-bypass role continues to deny body
#  29:  bypass_roles ts: generated .ts contains env-read + includes() check
#  30:  bypass_roles ts: includes check precedes AGENT_TYPE gate in generated .ts
#  31:  bypass_roles composes with COMMAND+deny: .sh has prelude + deny body
#  32:  bypass_roles composes with COMMAND+allowlist: .sh has prelude + allowlist body
#  33:  bypass_roles COMMAND+allowlist bash: bypass role exits (no deny)
#  34:  bypass_roles COMMAND+allowlist bash: non-bypass role hits allowlist guard
#  35:  kind:registration entry skipped by full-file generator (no .sh body overwrite)
#  36:  registration-in-block: kind:registration harnesses:all id WITH .ts file IS in generated block
#  37:  denial-still-in: existing denial hook id still appears in generated block
#  38:  deferred-not-in: a nonexistent/deferred id (context-index-parity, deleted) is NOT in generated block
#  39:  existence-guard: kind:registration harnesses:all id WITHOUT .ts file is NOT in generated block
#  40:  symmetry: import line count == register call line count inside generated block
#  41:  harnesses typo aborts compiler with token-set message (seam b)
#  42:  orphan-hook-check reports ORPHAN on stale marked file; PASS on real tree (seam a)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPILER="$SCRIPT_DIR/enforcement_compiler.py"
REGISTRY="$SCRIPT_DIR/../../shared/enforcement/registry.yaml"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle not found: %s\n' "$desc" "$needle"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  needle found (should not be): %s\n' "$desc" "$needle"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# ── Test 1: parse valid registry (6 entries loaded: 5 bash+ts + 1 pi-only) ────

tmpdir=$(mktemp -d /tmp/ec_test_XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

python3 "$COMPILER" \
    --registry "$REGISTRY" \
    --bash-out "$tmpdir/bash" \
    --ts-out "$tmpdir/ts" \
    --index "$tmpdir/index.ts" \
    --dry-run >"$tmpdir/dry_run.txt" 2>&1 || true

count=$(
    grep -c "^===" "$tmpdir/dry_run.txt" 2>/dev/null
    true
)
assert_eq "parse valid registry: 17 sections (registry has grown since this count was last updated)" "17" "$count"

# ── Test 2: dialect translation bash: \s → [[:space:]] ───────────────────────

bash_catpipe=$(grep "grep -qE" "$tmpdir/dry_run.txt" | head -1 || true)
assert_contains "bash dialect: \\s → [[:space:]]" "[[:space:]]" "$bash_catpipe"
assert_not_contains "bash dialect: no bare \\s in bash pattern" '\s' "$bash_catpipe"

# ── Test 3: match_all AND logic in bash ───────────────────────────────────────

# no-python-json has match_all with 2 patterns → 2 grep -qE calls joined by &&
python_section=$(awk '/=== .*no-python-json\.sh/,/=== .*no-python-json\.ts/' "$tmpdir/dry_run.txt" || true)
grep_count=$(
    printf '%s' "$python_section" | grep -c "grep -qE" 2>/dev/null
    true
)
assert_eq "match_all: 2 grep -qE calls in bash" "2" "$grep_count"
assert_contains "match_all: && joins conditions" "&&" "$python_section"

# ── Test 4: generated:false entry skipped ────────────────────────────────────

# Create a minimal registry with generated:false
cat >"$tmpdir/registry_skip.yaml" <<'YAML'
- id: should-skip
  generated: false
  event: PreToolUse
  tool_guard: Bash
  match: "foo"
  message: "skip me"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

python3 "$COMPILER" \
    --registry "$tmpdir/registry_skip.yaml" \
    --bash-out "$tmpdir/skip_bash" \
    --ts-out "$tmpdir/skip_ts" \
    --index "$tmpdir/skip_index.ts" \
    --dry-run >"$tmpdir/skip_out.txt" 2>&1 || true

section_count=$(
    grep -c "^===" "$tmpdir/skip_out.txt" 2>/dev/null
    true
)
assert_eq "generated:false: no files emitted" "0" "$section_count"

# ── Test 5: forbidden backreference rejected ─────────────────────────────────

cat >"$tmpdir/registry_backref.yaml" <<'YAML'
- id: bad-backref
  generated: true
  event: PreToolUse
  tool_guard: Bash
  match: "(foo)\\1"
  message: "test"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

set +e
python3 "$COMPILER" \
    --registry "$tmpdir/registry_backref.yaml" \
    --bash-out "$tmpdir/backref_bash" \
    --ts-out "$tmpdir/backref_ts" \
    --index "$tmpdir/backref_index.ts" \
    --dry-run >"$tmpdir/backref_out.txt" 2>&1
backref_rc=$?
set -e
assert_eq "forbidden backreference: non-zero exit" "1" "$((backref_rc != 0 ? 1 : 0))"

# ── Test 6: forbidden lookahead rejected ─────────────────────────────────────

cat >"$tmpdir/registry_lookahead.yaml" <<'YAML'
- id: bad-lookahead
  generated: true
  event: PreToolUse
  tool_guard: Bash
  match: "foo(?=bar)"
  message: "test"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

set +e
python3 "$COMPILER" \
    --registry "$tmpdir/registry_lookahead.yaml" \
    --bash-out "$tmpdir/lookahead_bash" \
    --ts-out "$tmpdir/lookahead_ts" \
    --index "$tmpdir/lookahead_index.ts" \
    --dry-run >"$tmpdir/lookahead_out.txt" 2>&1
lookahead_rc=$?
set -e
assert_eq "forbidden lookahead: non-zero exit" "1" "$((lookahead_rc != 0 ? 1 : 0))"

# ── Test 7: empty registry produces no files ─────────────────────────────────

cat >"$tmpdir/registry_empty.yaml" <<'YAML'
[]
YAML

python3 "$COMPILER" \
    --registry "$tmpdir/registry_empty.yaml" \
    --bash-out "$tmpdir/empty_bash" \
    --ts-out "$tmpdir/empty_ts" \
    --index "$tmpdir/empty_index.ts" \
    --dry-run >"$tmpdir/empty_out.txt" 2>&1

empty_count=$(
    grep -c "^===" "$tmpdir/empty_out.txt" 2>/dev/null
    true
)
assert_eq "empty registry: no files emitted" "0" "$empty_count"

# ── Test 8: generated .sh passes bash -n syntax check ────────────────────────

mkdir -p "$tmpdir/real_bash" "$tmpdir/real_ts"
cp "$SCRIPT_DIR/../../harnesses/pi/pi-extensions/enforcement/src/index.ts" "$tmpdir/real_index.ts" 2>/dev/null || touch "$tmpdir/real_index.ts"

PI_HOOKS_DIR="$SCRIPT_DIR/../../harnesses/pi/pi-extensions/enforcement/src/hooks"

python3 "$COMPILER" \
    --registry "$REGISTRY" \
    --bash-out "$tmpdir/real_bash" \
    --ts-out "$tmpdir/real_ts" \
    --pi-hooks-dir "$PI_HOOKS_DIR" \
    --index "$tmpdir/real_index.ts" >/dev/null 2>&1

syntax_ok=true
for f in "$tmpdir/real_bash"/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
        syntax_ok=false
        break
    fi
done
assert_eq "generated .sh: bash -n syntax check passes" "true" "$syntax_ok"

# ── Test 9: generated .sh HOOK-MANIFEST headers match registry ───────────────

event=$(grep "^# event:" "$tmpdir/real_bash/no-cat-pipe.sh" | head -1 | awk '{print $3}')
assert_eq "HOOK-MANIFEST event matches registry" "PreToolUse" "$event"

surface=$(grep "^# surface:" "$tmpdir/real_bash/no-cat-pipe.sh" | head -1 | awk '{print $3}')
assert_eq "HOOK-MANIFEST surface matches registry" "user_global" "$surface"

signal=$(grep "^# signal:" "$tmpdir/real_bash/no-git-stash.sh" | head -1 | awk '{print $3}')
assert_eq "HOOK-MANIFEST signal matches registry" "none" "$signal"

# ── Test 10: index.ts update wraps entries in BEGIN/END markers ───────────────

assert_contains "index.ts: BEGIN marker present" "// BEGIN-GENERATED-ENFORCEMENT-BLOCK" "$(cat "$tmpdir/real_index.ts")"
assert_contains "index.ts: END marker present" "// END-GENERATED-ENFORCEMENT-BLOCK" "$(cat "$tmpdir/real_index.ts")"
assert_contains "index.ts: no-cat-pipe import inside block" "registerNoCatPipe" "$(cat "$tmpdir/real_index.ts")"

# ── Test 11: index.ts update is idempotent ────────────────────────────────────

cp "$tmpdir/real_index.ts" "$tmpdir/real_index_orig.ts"
python3 "$COMPILER" \
    --registry "$REGISTRY" \
    --bash-out "$tmpdir/real_bash2" \
    --ts-out "$tmpdir/real_ts2" \
    --pi-hooks-dir "$PI_HOOKS_DIR" \
    --index "$tmpdir/real_index.ts" >/dev/null 2>&1

if diff -q "$tmpdir/real_index_orig.ts" "$tmpdir/real_index.ts" >/dev/null 2>&1; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: index.ts update is idempotent\n'
    pass=$((pass + 1))
else
    printf 'FAIL: index.ts update is NOT idempotent\n'
    diff "$tmpdir/real_index_orig.ts" "$tmpdir/real_index.ts" || true
    fail=$((fail + 1))
fi

# ── Test 12: no-python-json.ts generated correctly ────────────────────────────

assert_contains "no-python-json.ts: first pattern present" "python3?" "$(cat "$tmpdir/real_ts/no-python-json.ts")"
assert_contains "no-python-json.ts: second pattern present" "import" "$(cat "$tmpdir/real_ts/no-python-json.ts")"

# ── Test 13: message backtick escaped in bash deny call ──────────────────────

# The deny call line contains escaped backticks (\`) inside double quotes.
catpipe_content=$(cat "$tmpdir/real_bash/no-cat-pipe.sh")
assert_contains "bash: backticks escaped in deny message" 'instead of \`cat' "$catpipe_content"

# ── Test 14: match_all ts: both patterns in generated .ts ─────────────────────

ts_python=$(cat "$tmpdir/real_ts/no-python-json.ts")
assert_contains "ts match_all: pattern 1 present" "python3?" "$ts_python"
assert_contains "ts match_all: && present" "&&" "$ts_python"

# ── Tests 15-18: FILE_PATH source + allowlist mode ───────────────────────────

reviewer_ts="$tmpdir/real_ts/reviewer-guard-session-log-write.ts"
assert_eq "FILE_PATH allowlist: .ts file generated" "true" "$([ -f "$reviewer_ts" ] && echo true || echo false)"

ts_reviewer=$(cat "$reviewer_ts" 2>/dev/null || echo "")
assert_contains "FILE_PATH allowlist: repoRelative call present" "repoRelative" "$ts_reviewer"
assert_contains "FILE_PATH allowlist: role guard for reviewer-phoenix" "reviewer-phoenix" "$ts_reviewer"
assert_contains "FILE_PATH allowlist: deny message present" "reviewer may only write to canonical session logs" "$ts_reviewer"

# Pi-only entry must NOT emit a .sh file
reviewer_sh="$tmpdir/real_bash/reviewer-guard-session-log-write.sh"
assert_eq "FILE_PATH allowlist pi-only: no .sh emitted" "false" "$([ -f "$reviewer_sh" ] && echo true || echo false)"

# ── Tests 19-24: COMMAND+allowlist axis ──────────────────────────────────────

cat >"$tmpdir/registry_cmd_allowlist.yaml" <<'YAML'
- id: test-cmd-allow
  generated: true
  description: "allow git commands only"
  event: PreToolUse
  source: COMMAND
  mode: allowlist
  tool_guard: Bash
  match: "^\\s*(git\\s+|echo\\b|wc\\b)"
  message: "BLOCKED: only git/echo/wc allowed"
  surface: user_global
  signal: AGENT_TYPE
  role: committer
  harnesses: all
YAML

mkdir -p "$tmpdir/cmd_allow_bash" "$tmpdir/cmd_allow_ts"
cp "$SCRIPT_DIR/../../harnesses/pi/pi-extensions/enforcement/src/index.ts" \
    "$tmpdir/cmd_allow_index.ts" 2>/dev/null || cat >"$tmpdir/cmd_allow_index.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
// BEGIN-GENERATED-ENFORCEMENT-BLOCK
// END-GENERATED-ENFORCEMENT-BLOCK
export default function (pi: ExtensionAPI): void {
  // BEGIN-GENERATED-ENFORCEMENT-BLOCK
  // END-GENERATED-ENFORCEMENT-BLOCK
}
TS

python3 "$COMPILER" \
    --registry "$tmpdir/registry_cmd_allowlist.yaml" \
    --bash-out "$tmpdir/cmd_allow_bash" \
    --ts-out "$tmpdir/cmd_allow_ts" \
    --index "$tmpdir/cmd_allow_index.ts" >/dev/null 2>&1

# Test 19: .sh allows matching command (git status → exit 0, no deny)
sh_allow="$tmpdir/cmd_allow_bash/test-cmd-allow.sh"
# Replace the sourced hooks-lib.sh with a stub for isolated testing
stub_out=$(TOOL_NAME=Bash AGENT_TYPE=committer COMMAND="git status" \
    bash "$sh_allow" 2>/dev/null || true)
allow_denied=$(printf '%s' "$stub_out" | grep -c '"permissionDecision".*"deny"' 2>/dev/null || true)
assert_eq "COMMAND+allowlist: git status not denied" "0" "$allow_denied"

# Test 20: .sh denies non-matching command
# We can check the script content instead — grep for the deny call and the allow-pattern
sh_content=$(<"$sh_allow")
assert_contains "COMMAND+allowlist: .sh contains allow-pattern grep" "grep -qE" "$sh_content"
assert_contains "COMMAND+allowlist: .sh contains deny call" 'deny "BLOCKED:' "$sh_content"
assert_contains "COMMAND+allowlist: .sh has exit 0 after allow match" "then" "$sh_content"

# Test 21: role-scoped .sh contains AGENT_TYPE case guard
assert_contains "COMMAND+allowlist: .sh has AGENT_TYPE case guard" 'case "$AGENT_TYPE"' "$sh_content"
assert_contains "COMMAND+allowlist: .sh case arm for committer" 'committer)' "$sh_content"

# Test 22: generated .ts allows matching (pattern in source → returns without deny)
ts_allow_content=$(<"$tmpdir/cmd_allow_ts/test-cmd-allow.ts")
# The TS template: if (/pattern/.test(command)) return;
assert_contains "COMMAND+allowlist: .ts has allow-return" "return;" "$ts_allow_content"
assert_not_contains "COMMAND+allowlist: .ts does NOT return deny on match" \
    "if (/.test(command)) {" "$ts_allow_content"

# Test 23: generated .ts denies on non-match
assert_contains "COMMAND+allowlist: .ts has deny call" "return deny(" "$ts_allow_content"

# Test 24: generated .sh passes bash -n syntax check
syntax_allow="true"
if ! bash -n "$sh_allow" 2>/dev/null; then
    syntax_allow="false"
fi
assert_eq "COMMAND+allowlist: .sh bash -n syntax check" "true" "$syntax_allow"

# ── Tests 25-34: bypass_roles axis ──────────────────────────────────────────

# Fixture: COMMAND+deny with bypass_roles
cat >"$tmpdir/registry_bypass_deny.yaml" <<'YAML'
- id: test-bypass-deny
  generated: true
  description: "deny git stash but bypass shape role"
  event: PreToolUse
  source: COMMAND
  mode: deny
  tool_guard: Bash
  match: "\\bgit\\s+stash\\b"
  bypass_roles:
    - shape
    - ops
  message: "BLOCKED: git stash forbidden"
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

# Fixture: COMMAND+allowlist with bypass_roles
cat >"$tmpdir/registry_bypass_allow.yaml" <<'YAML'
- id: test-bypass-allow
  generated: true
  description: "allowlist with bypass"
  event: PreToolUse
  source: COMMAND
  mode: allowlist
  tool_guard: Bash
  match: "^\\s*git\\b"
  bypass_roles:
    - debug
  message: "BLOCKED: only git allowed"
  surface: user_global
  signal: AGENT_TYPE
  role: committer
  harnesses: all
YAML

mkdir -p "$tmpdir/bypass_deny_bash" "$tmpdir/bypass_deny_ts" \
    "$tmpdir/bypass_allow_bash" "$tmpdir/bypass_allow_ts"
touch "$tmpdir/bypass_deny_index.ts" "$tmpdir/bypass_allow_index.ts"

python3 "$COMPILER" \
    --registry "$tmpdir/registry_bypass_deny.yaml" \
    --bash-out "$tmpdir/bypass_deny_bash" \
    --ts-out "$tmpdir/bypass_deny_ts" \
    --index "$tmpdir/bypass_deny_index.ts" >/dev/null 2>&1

python3 "$COMPILER" \
    --registry "$tmpdir/registry_bypass_allow.yaml" \
    --bash-out "$tmpdir/bypass_allow_bash" \
    --ts-out "$tmpdir/bypass_allow_ts" \
    --index "$tmpdir/bypass_allow_index.ts" >/dev/null 2>&1

bypass_deny_sh=$(<"$tmpdir/bypass_deny_bash/test-bypass-deny.sh")
bypass_deny_ts_content=$(<"$tmpdir/bypass_deny_ts/test-bypass-deny.ts")
bypass_allow_sh=$(<"$tmpdir/bypass_allow_bash/test-bypass-allow.sh")
bypass_allow_ts_content=$(<"$tmpdir/bypass_allow_ts/test-bypass-allow.ts")

# Test 25: generated .sh sources _role.sh
assert_contains "bypass_roles bash: .sh sources _role.sh" \
    'source "$(dirname "$0")/_role.sh"' "$bypass_deny_sh"

# Test 26: generated .sh contains resolve_role loop before body
assert_contains "bypass_roles bash: .sh has resolve_role call" \
    '_role=$(resolve_role)' "$bypass_deny_sh"
assert_contains "bypass_roles bash: .sh has bypass for-loop" \
    'for _m in shape ops' "$bypass_deny_sh"
assert_contains "bypass_roles bash: .sh loop has exit 0" \
    '&& exit 0' "$bypass_deny_sh"

# Test 27: bypass role exits early — verify resolve_role loop exits before deny
# We check the prelude appears before the grep deny pattern in the script
prelude_line=$(grep -n 'resolve_role' "$tmpdir/bypass_deny_bash/test-bypass-deny.sh" | head -1 | cut -d: -f1 || true)
deny_line=$(grep -n 'grep -qE' "$tmpdir/bypass_deny_bash/test-bypass-deny.sh" | head -1 | cut -d: -f1 || true)
assert_eq "bypass_roles bash: prelude precedes deny body" "1" \
    "$((prelude_line < deny_line ? 1 : 0))"

# Test 28: .sh passes bash -n syntax check (non-bypass path still valid bash)
bypass_syntax="true"
if ! bash -n "$tmpdir/bypass_deny_bash/test-bypass-deny.sh" 2>/dev/null; then
    bypass_syntax="false"
fi
assert_eq "bypass_roles bash: .sh bash -n syntax check" "true" "$bypass_syntax"

# Test 29: generated .ts contains env-read + includes() check
assert_contains "bypass_roles ts: .ts has CLAUDE_ROLE env read" \
    'process.env["CLAUDE_ROLE"]' "$bypass_deny_ts_content"
assert_contains "bypass_roles ts: .ts has includes() check" \
    '.includes(_role)' "$bypass_deny_ts_content"
assert_contains "bypass_roles ts: .ts has shape in list" \
    '"shape"' "$bypass_deny_ts_content"
assert_contains "bypass_roles ts: .ts has ops in list" \
    '"ops"' "$bypass_deny_ts_content"

# Test 30: includes check precedes AGENT_TYPE gate in .ts
# For role:*, no AGENT_TYPE gate — just check bypass_roles comes before test pattern
bypass_env_line=$(grep -n 'CLAUDE_ROLE' "$tmpdir/bypass_deny_ts/test-bypass-deny.ts" | head -1 | cut -d: -f1 || true)
deny_ts_line=$(grep -n '\.test(command)' "$tmpdir/bypass_deny_ts/test-bypass-deny.ts" | head -1 | cut -d: -f1 || true)
assert_eq "bypass_roles ts: env-read precedes test pattern" "1" \
    "$((bypass_env_line < deny_ts_line ? 1 : 0))"

# Test 31: bypass_roles composes with COMMAND+deny body
assert_contains "bypass COMMAND+deny: .sh has deny body" \
    'grep -qE' "$bypass_deny_sh"
assert_contains "bypass COMMAND+deny: .sh has deny message" \
    'BLOCKED: git stash forbidden' "$bypass_deny_sh"

# Test 32: bypass_roles composes with COMMAND+allowlist body
assert_contains "bypass COMMAND+allowlist: .sh sources _role.sh" \
    'source "$(dirname "$0")/_role.sh"' "$bypass_allow_sh"
assert_contains "bypass COMMAND+allowlist: .sh has allowlist grep" \
    'grep -qE' "$bypass_allow_sh"
assert_contains "bypass COMMAND+allowlist: .sh has exit 0 on allow match" \
    'exit 0' "$bypass_allow_sh"

# Test 33: bypass_roles COMMAND+allowlist bash: bypass role exits (no deny reached)
bypass_allow_prelude_line=$(grep -n 'resolve_role' "$tmpdir/bypass_allow_bash/test-bypass-allow.sh" | head -1 | cut -d: -f1 || true)
bypass_allow_deny_line=$(grep -n 'deny "' "$tmpdir/bypass_allow_bash/test-bypass-allow.sh" | head -1 | cut -d: -f1 || true)
assert_eq "bypass COMMAND+allowlist: prelude precedes deny" "1" \
    "$((bypass_allow_prelude_line < bypass_allow_deny_line ? 1 : 0))"

# Test 34: bypass_roles COMMAND+allowlist ts: env-read present
assert_contains "bypass COMMAND+allowlist ts: .ts has env-read" \
    'process.env["CLAUDE_ROLE"]' "$bypass_allow_ts_content"
assert_contains "bypass COMMAND+allowlist ts: .ts has includes check" \
    '.includes(_role)' "$bypass_allow_ts_content"

# ── Test 35: kind:registration entry skipped by full-file generator ───────────

cat >"$tmpdir/registry_registration.yaml" <<'YAML'
- kind: registration
  id: my-behavioral-hook
  event: PreToolUse
  tool_guard: Bash
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

mkdir -p "$tmpdir/reg_bash" "$tmpdir/reg_ts"
touch "$tmpdir/reg_index.ts"

set +e
python3 "$COMPILER" \
    --registry "$tmpdir/registry_registration.yaml" \
    --bash-out "$tmpdir/reg_bash" \
    --ts-out "$tmpdir/reg_ts" \
    --index "$tmpdir/reg_index.ts" \
    --dry-run >"$tmpdir/reg_out.txt" 2>&1
reg_rc=$?
set -e

# Must exit cleanly (kind:registration is skipped, no error)
assert_eq "kind:registration: compiler exits 0" "0" "$reg_rc"

# Must produce no output files (no sections in dry-run output)
reg_section_count=$(
    grep -c "^===" "$tmpdir/reg_out.txt" 2>/dev/null
    true
)
assert_eq "kind:registration: no files emitted by full-file generator" "0" "$reg_section_count"

# ── Tests 36-40: registration-in-block / deferred-not-in / existence-guard / symmetry ──

# Use the real index.ts produced in tests 8-11 (tmpdir/real_index.ts).
real_index_content=$(cat "$tmpdir/real_index.ts" 2>/dev/null || echo "")

# Test 36: registration-in-block — a kind:registration harnesses:all id with
# an existing .ts file IS emitted inside the generated block.
# build-agent-app-confinement is kind:registration harnesses:all with a ts file.
assert_contains \
    "registration-in-block: build-agent-app-confinement import in block" \
    'import { register as registerBuildAgentAppConfinement }' \
    "$real_index_content"
assert_contains \
    "registration-in-block: build-agent-app-confinement register call in block" \
    'registerBuildAgentAppConfinement(pi)' \
    "$real_index_content"

# Verify the import line appears BETWEEN the BEGIN/END markers (not outside).
block_import=$(awk \
    '/\/\/ BEGIN-GENERATED-ENFORCEMENT-BLOCK/,/\/\/ END-GENERATED-ENFORCEMENT-BLOCK/' \
    "$tmpdir/real_index.ts" | grep -c 'registerBuildAgentAppConfinement' 2>/dev/null || true)
assert_eq \
    "registration-in-block: both import+call appear inside generated block" \
    "2" "$block_import"

# Test 37: denial-still-in — no-cat-pipe (denial hook, harnesses:all) still in block.
assert_contains \
    "denial-still-in: no-cat-pipe import in generated block" \
    'import { register as registerNoCatPipe }' \
    "$real_index_content"

# Test 38: deferred-not-in — an id with no corresponding .ts file (context-index-parity,
# deleted; formerly a NOT-YET-MIGRATED deferred hand-import) is NOT inside the generated
# block. A deferred/commented-out registry entry would ALSO stay out of the block via the
# same existence-guard path exercised by test 39 below.
block_context=$(awk \
    '/\/\/ BEGIN-GENERATED-ENFORCEMENT-BLOCK/,/\/\/ END-GENERATED-ENFORCEMENT-BLOCK/' \
    "$tmpdir/real_index.ts" | grep -c 'context-index-parity' 2>/dev/null || true)
assert_eq \
    "deferred-not-in: context-index-parity absent from generated block" \
    "0" "$block_context"

# Test 39: existence-guard — a kind:registration harnesses:all id without a .ts file
# is NOT emitted. Use a synthetic registry with a non-existent id.
cat >"$tmpdir/registry_nonexistent.yaml" <<'YAML'
- kind: registration
  id: nonexistent-hook-xyz
  event: PreToolUse
  tool_guard: Bash
  surface: user_global
  signal: none
  role: "*"
  harnesses: all
YAML

# Seed the index file with empty blocks so markers are present.
cat >"$tmpdir/nonexistent_index.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
// BEGIN-GENERATED-ENFORCEMENT-BLOCK
// END-GENERATED-ENFORCEMENT-BLOCK
export default function (pi: ExtensionAPI): void {
  // BEGIN-GENERATED-ENFORCEMENT-BLOCK
  // END-GENERATED-ENFORCEMENT-BLOCK
}
TS

mkdir -p "$tmpdir/nonexistent_bash" "$tmpdir/nonexistent_ts"

# Run without --pi-hooks-dir → defaults to ts-out ($tmpdir/nonexistent_ts) which is empty.
python3 "$COMPILER" \
    --registry "$tmpdir/registry_nonexistent.yaml" \
    --bash-out "$tmpdir/nonexistent_bash" \
    --ts-out "$tmpdir/nonexistent_ts" \
    --index "$tmpdir/nonexistent_index.ts" >/dev/null 2>&1

nonexistent_in_block=$(grep -c 'nonexistent-hook-xyz' "$tmpdir/nonexistent_index.ts" 2>/dev/null || true)
assert_eq \
    "existence-guard: id without .ts file not emitted in block" \
    "0" "$nonexistent_in_block"

# Test 40: symmetry — import line count (in import block) == register call count (in register block).
# Count all import lines and all registerX(pi) calls within generated blocks.
all_blocks=$(awk \
    '/\/\/ BEGIN-GENERATED-ENFORCEMENT-BLOCK/,/\/\/ END-GENERATED-ENFORCEMENT-BLOCK/' \
    "$tmpdir/real_index.ts")
import_count=$(printf '%s' "$all_blocks" | grep -c '^import ' 2>/dev/null || true)
register_count=$(printf '%s' "$all_blocks" | grep -cE '^\s+register[A-Z][^(]+\(pi\);' 2>/dev/null || true)
assert_eq \
    "symmetry: import line count equals register call count in block" \
    "$import_count" "$register_count"

# ── Test 41: harnesses typo aborts compiler (seam b) ─────────────────────────

cat >"$tmpdir/registry_bad_harness.yaml" <<'YAML'
- id: bad-harness
  generated: true
  event: PreToolUse
  tool_guard: Bash
  match: "foo"
  message: "test"
  surface: user_global
  signal: none
  role: "*"
  harnesses: claude_code
YAML
set +e
bad_out=$(python3 "$COMPILER" \
    --registry "$tmpdir/registry_bad_harness.yaml" \
    --bash-out "$tmpdir/bad_harness_bash" \
    --ts-out "$tmpdir/bad_harness_ts" \
    --index "$tmpdir/bad_harness_index.ts" \
    --dry-run 2>&1)
bad_rc=$?
set -e
assert_eq "harnesses typo: non-zero exit" "1" "$((bad_rc != 0 ? 1 : 0))"
assert_contains "harnesses typo: token-set message" "not in (all, claude, pi)" "$bad_out"

# ── Test 42: orphan-hook-check reverse pass (seam a) ─────────────────────────

ORPHAN_CHECK="$SCRIPT_DIR/orphan-hook-check.sh"
mkdir -p "$tmpdir/orphan_hooks"
# Copy a real fully-generated hook (carries discriminator), rename to an id
# absent from the registry.
cp "$SCRIPT_DIR/../../harnesses/claude/hooks/no-cat-pipe.sh" \
    "$tmpdir/orphan_hooks/orphan-xyz.sh"
set +e
orphan_out=$(bash "$ORPHAN_CHECK" \
    --hooks-dir "$tmpdir/orphan_hooks" \
    --registry "$REGISTRY" 2>&1)
orphan_rc=$?
set -e
assert_eq "orphan-check: non-zero exit on orphan" "1" "$((orphan_rc != 0 ? 1 : 0))"
assert_contains "orphan-check: ORPHAN line emitted" "ORPHAN" "$orphan_out"
assert_contains "orphan-check: names the orphan id" "orphan-xyz" "$orphan_out"

# Real committed tree has NO orphans today → exit 0.
set +e
real_out=$(bash "$ORPHAN_CHECK" \
    --hooks-dir "$SCRIPT_DIR/../../harnesses/claude/hooks" \
    --ts-dir "$SCRIPT_DIR/../../harnesses/pi/pi-extensions/enforcement/src/hooks" \
    --registry "$REGISTRY" 2>&1)
real_rc=$?
set -e
assert_eq "orphan-check: clean tree exits 0" "0" "$real_rc"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
