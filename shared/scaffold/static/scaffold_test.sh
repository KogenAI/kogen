#!/usr/bin/env bash
# scaffold_test.sh — hermetic tests for static/scaffold.sh + codegen-scaffold.
#
# Asserts:
#  (a) assets/css/app.css contains "tailwindcss"
#  (b) package.json name == slug
#  (c) package.json has "serve" and "build" scripts
#  (d) static/index.html contains app-name
#  (e) README.md contains app-name + "npm install" + "npm run build" + "npm run serve"
#  (f) static/images/ and static/js/ directories exist
#  codegen-scaffold smoke:
#  (g) bad --stack=x exits 2
#  (h) missing --slug for create exits 2
#  (i) integrate --stack=phoenix creates AGENTS.md, CLAUDE.md, codegen/rules, codegen/usage_rules symlinks
#  (j) integrate creates codegen/recipes symlink
#  (k) integrate creates Makefile with format: target
#  (l) integrate appends ## Codegen integration to README.md
#  (m) idempotency: second run produces exactly one format: line and one ## Codegen integration heading
#  (n) pre-existing format: target is not clobbered (custom recipe survives)
#  (o) integrate appends AGENTS.md, CLAUDE.md, /codegen/ to .gitignore
#  (p) integrate on a dir with no .gitignore creates one with the markers
#  (q) integrate is idempotent for gitignore (re-running doesn't duplicate lines)
#  (ad) --recipe-source plants codegen/recipes-extra symlink, keeps generic codegen/recipes
#  (ae) no --recipe-source → recipes-extra absent (default unchanged)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STATIC_SCAFFOLD="$SCRIPT_DIR/scaffold.sh"
CODEGEN_SCAFFOLD="$CODEGEN_ROOT/codegen-scaffold"

pass=0
fail=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q in output\n' "$desc" "$needle"
        fail=$((fail + 1))
    fi
}

assert_file_exists() {
    local desc="$1"
    local path="$2"
    if [[ -e "$path" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — file not found: %s\n' "$desc" "$path"
        fail=$((fail + 1))
    fi
}

assert_exit() {
    local desc="$1"
    local expected_exit="$2"
    local actual_exit="$3"
    if [[ "$actual_exit" == "$expected_exit" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected exit %s, got %s\n' "$desc" "$expected_exit" "$actual_exit"
        fail=$((fail + 1))
    fi
}

# ── Setup: hermetic tmp dir ───────────────────────────────────────────────────
BASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BASE_TMP"; }
trap cleanup EXIT

TMPDIR="$BASE_TMP/scaffold_out"
mkdir -p "$TMPDIR"

SLUG="my-test-app"
APP_NAME="My Test App"

# ── Run static/scaffold.sh ────────────────────────────────────────────────────
"$STATIC_SCAFFOLD" "$SLUG" "$TMPDIR" --app-name "$APP_NAME"

# (a) assets/css/app.css contains "tailwindcss"
CSS_CONTENT="$(<"$TMPDIR/assets/css/app.css")"
assert_contains "assets/css/app.css contains tailwindcss" "$CSS_CONTENT" "tailwindcss"

# (b) package.json name == slug
PKG_CONTENT="$(<"$TMPDIR/package.json")"
assert_contains "package.json name field is slug" "$PKG_CONTENT" "\"name\": \"$SLUG\""

# (c) package.json has "serve" and "build" scripts
assert_contains "package.json has serve script" "$PKG_CONTENT" "\"serve\""
assert_contains "package.json has build script" "$PKG_CONTENT" "\"build\""

# (d) static/index.html contains app-name
INDEX_CONTENT="$(<"$TMPDIR/static/index.html")"
assert_contains "static/index.html contains app-name" "$INDEX_CONTENT" "$APP_NAME"

# (e) README.md contains app-name + npm commands
README_CONTENT="$(<"$TMPDIR/README.md")"
assert_contains "README.md contains app-name" "$README_CONTENT" "$APP_NAME"
assert_contains "README.md contains npm install" "$README_CONTENT" "npm install"
assert_contains "README.md contains npm run build" "$README_CONTENT" "npm run build"
assert_contains "README.md contains npm run serve" "$README_CONTENT" "npm run serve"

# (f) static/images/ and static/js/ exist
assert_file_exists "static/images/ directory exists" "$TMPDIR/static/images"
assert_file_exists "static/js/ directory exists" "$TMPDIR/static/js"

# ── codegen-scaffold smoke tests ──────────────────────────────────────────────

# (g) bad --stack=x exits 2
BAD_STACK_EXIT=0
"$CODEGEN_SCAFFOLD" create --stack=bad_stack --cwd="$BASE_TMP/bad" --slug=test 2>/dev/null || BAD_STACK_EXIT=$?
assert_exit "bad --stack exits 2" "2" "$BAD_STACK_EXIT"

# (h) missing --slug for create exits 2
MISSING_SLUG_EXIT=0
"$CODEGEN_SCAFFOLD" create --stack=phoenix --cwd="$BASE_TMP/noslug" 2>/dev/null || MISSING_SLUG_EXIT=$?
assert_exit "missing --slug for create exits 2" "2" "$MISSING_SLUG_EXIT"

# (i) integrate --stack=phoenix creates 4 symlinks in tmp cwd
SYMLINKS_CWD="$BASE_TMP/symlinks_test"
mkdir -p "$SYMLINKS_CWD/codegen"

"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$SYMLINKS_CWD" --slug=test-app

assert_file_exists "integrate creates AGENTS.md" "$SYMLINKS_CWD/AGENTS.md"
assert_file_exists "integrate creates CLAUDE.md" "$SYMLINKS_CWD/CLAUDE.md"
assert_file_exists "integrate creates codegen/rules symlink" "$SYMLINKS_CWD/codegen/rules"
assert_file_exists "integrate creates codegen/usage_rules symlink" "$SYMLINKS_CWD/codegen/usage_rules"

# Verify they are actually symlinks (not files)
if [[ -L "$SYMLINKS_CWD/AGENTS.md" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: AGENTS.md is a symlink\n'
    pass=$((pass + 1))
else
    printf 'FAIL: AGENTS.md is not a symlink\n'
    fail=$((fail + 1))
fi

if [[ -L "$SYMLINKS_CWD/codegen/rules" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: codegen/rules is a symlink\n'
    pass=$((pass + 1))
else
    printf 'FAIL: codegen/rules is not a symlink\n'
    fail=$((fail + 1))
fi

# (j) recipes symlink
if [[ -L "$SYMLINKS_CWD/codegen/recipes" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: codegen/recipes is a symlink\n'
    pass=$((pass + 1))
else
    printf 'FAIL: codegen/recipes is not a symlink\n'
    fail=$((fail + 1))
fi
assert_file_exists "codegen/recipes/INDEX.md exists via symlink" "$SYMLINKS_CWD/codegen/recipes/INDEX.md"

# (k) format: target in Makefile
FORMAT_COUNT=$(grep -c '^format:' "$SYMLINKS_CWD/Makefile" || true)
check "Makefile has exactly one format: target" "1" "$FORMAT_COUNT"

# (l) README.md contains ## Codegen integration heading
README_CODEGEN=$(grep -cF '## Codegen integration' "$SYMLINKS_CWD/README.md" || true)
check "README.md contains ## Codegen integration heading" "1" "$README_CODEGEN"

# (m) idempotency: second run must not duplicate format: or ## Codegen integration
"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$SYMLINKS_CWD" --slug=test-app

check "exactly one format: line after re-run" "1" "$(grep -c '^format:' "$SYMLINKS_CWD/Makefile" || true)"
check "exactly one Codegen integration heading after re-run" "1" "$(grep -cF '## Codegen integration' "$SYMLINKS_CWD/README.md" || true)"

# (n) pre-existing format: target is not clobbered
NOCLOBBER_CWD="$BASE_TMP/noclobber_test"
mkdir -p "$NOCLOBBER_CWD/codegen"
printf 'format:\n\tmy-custom-formatter --all\n' >"$NOCLOBBER_CWD/Makefile"
ORIGINAL_FORMAT_COUNT=$(grep -c '^format:' "$NOCLOBBER_CWD/Makefile" || true)

"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$NOCLOBBER_CWD" --slug=test-app

AFTER_FORMAT_COUNT=$(grep -c '^format:' "$NOCLOBBER_CWD/Makefile" || true)
check "no-clobber: pre-existing format: target count unchanged" "$ORIGINAL_FORMAT_COUNT" "$AFTER_FORMAT_COUNT"
assert_contains "custom format recipe body preserved" "$(cat "$NOCLOBBER_CWD/Makefile")" "my-custom-formatter --all"

# (o) integrate appends machine-local symlink markers to .gitignore
GITIGNORE_CWD="$BASE_TMP/gitignore_test"
mkdir -p "$GITIGNORE_CWD"
printf '*.beam\n_build/\n' >"$GITIGNORE_CWD/.gitignore"

"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$GITIGNORE_CWD" --slug=test-app

GITIGNORE_CONTENT="$(cat "$GITIGNORE_CWD/.gitignore")"
assert_contains "gitignore contains AGENTS.md entry" "$GITIGNORE_CONTENT" "AGENTS.md"
assert_contains "gitignore contains CLAUDE.md entry" "$GITIGNORE_CONTENT" "CLAUDE.md"
assert_contains "gitignore contains /codegen/ entry" "$GITIGNORE_CONTENT" "/codegen/"
assert_contains "gitignore contains marker comment" "$GITIGNORE_CONTENT" "# Codegen machine-local symlinks (do not commit)"

# (p) integrate on a dir with no .gitignore creates one with the markers
NOGITIGNORE_CWD="$BASE_TMP/nogitignore_test"
mkdir -p "$NOGITIGNORE_CWD"

"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$NOGITIGNORE_CWD" --slug=test-app

assert_file_exists "integrate creates .gitignore when absent" "$NOGITIGNORE_CWD/.gitignore"
CREATED_GITIGNORE="$(cat "$NOGITIGNORE_CWD/.gitignore")"
assert_contains "created .gitignore contains AGENTS.md" "$CREATED_GITIGNORE" "AGENTS.md"
assert_contains "created .gitignore contains CLAUDE.md" "$CREATED_GITIGNORE" "CLAUDE.md"
assert_contains "created .gitignore contains /codegen/" "$CREATED_GITIGNORE" "/codegen/"

# (q) integrate is idempotent for gitignore (re-running doesn't duplicate lines)
"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$GITIGNORE_CWD" --slug=test-app

AGENTS_COUNT=$(grep -c '^AGENTS.md$' "$GITIGNORE_CWD/.gitignore" || true)
CLAUDE_COUNT=$(grep -c '^CLAUDE.md$' "$GITIGNORE_CWD/.gitignore" || true)
CODEGEN_COUNT=$(grep -c '^/codegen/$' "$GITIGNORE_CWD/.gitignore" || true)
MARKER_COUNT=$(grep -cF '# Codegen machine-local symlinks (do not commit)' "$GITIGNORE_CWD/.gitignore" || true)
check "gitignore idempotent: AGENTS.md appears exactly once" "1" "$AGENTS_COUNT"
check "gitignore idempotent: CLAUDE.md appears exactly once" "1" "$CLAUDE_COUNT"
check "gitignore idempotent: /codegen/ appears exactly once" "1" "$CODEGEN_COUNT"
check "gitignore idempotent: marker appears exactly once" "1" "$MARKER_COUNT"

# ── New tests: Phase A–D assertions ──────────────────────────────────────────

# (r) Static scaffold .gitignore has non-marker entries
# Run scaffold into a fresh dir and check gitignore entries
GITIGNORE_STATIC_CWD="$BASE_TMP/gitignore_static_test"
mkdir -p "$GITIGNORE_STATIC_CWD"
"$STATIC_SCAFFOLD" "$SLUG" "$GITIGNORE_STATIC_CWD" --app-name "$APP_NAME"
STATIC_GI_CONTENT="$(cat "$GITIGNORE_STATIC_CWD/.gitignore")"
assert_contains "static gitignore has /package-lock.json" "$STATIC_GI_CONTENT" "/package-lock.json"
assert_contains "static gitignore has /node_modules/" "$STATIC_GI_CONTENT" "/node_modules/"
assert_contains "static gitignore has /public/" "$STATIC_GI_CONTENT" "/public/"
assert_contains "static gitignore has current" "$STATIC_GI_CONTENT" "current"
assert_contains "static gitignore has public-*" "$STATIC_GI_CONTENT" "public-*"
assert_contains "static gitignore has .DS_Store" "$STATIC_GI_CONTENT" ".DS_Store"

# (s) Integrate adds machine-local marker on top of existing static gitignore (no duplicate)
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$GITIGNORE_STATIC_CWD" --slug="$SLUG"
AFTER_INTEGRATE_GI="$(cat "$GITIGNORE_STATIC_CWD/.gitignore")"
assert_contains "after integrate: gitignore still has /package-lock.json" "$AFTER_INTEGRATE_GI" "/package-lock.json"
assert_contains "after integrate: gitignore has machine-local marker" "$AFTER_INTEGRATE_GI" "# Codegen machine-local symlinks (do not commit)"
AGENTS_COUNT_STATIC=$(grep -c '^AGENTS.md$' "$GITIGNORE_STATIC_CWD/.gitignore" || true)
check "static gitignore AGENTS.md idempotency: exactly once" "1" "$AGENTS_COUNT_STATIC"

# (t) Boundary guard: no 'combobulate' in PROJECT_CONTEXT templates or scaffold scripts
BOUNDARY_MATCHES="$(grep -ri "combobulate" \
    "$CODEGEN_ROOT/shared/scaffold/static/scaffold.sh" \
    "$CODEGEN_ROOT/shared/scaffold/phoenix/scaffold.sh" \
    "$CODEGEN_ROOT/shared/apps/PROJECT_CONTEXT-phoenix-template.md" \
    "$CODEGEN_ROOT/shared/apps/PROJECT_CONTEXT-static-template.md" \
    "$CODEGEN_ROOT/codegen-scaffold" 2>/dev/null || true)"
check "boundary guard: no 'combobulate' in scaffold files" "" "$BOUNDARY_MATCHES"

# (u) Integrate writes PROJECT_CONTEXT.md
PROJECT_CONTEXT_CWD="$BASE_TMP/project_context_test"
mkdir -p "$PROJECT_CONTEXT_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$PROJECT_CONTEXT_CWD" --slug=test-pc
assert_file_exists "integrate writes PROJECT_CONTEXT.md" "$PROJECT_CONTEXT_CWD/PROJECT_CONTEXT.md"
PC_CONTENT="$(cat "$PROJECT_CONTEXT_CWD/PROJECT_CONTEXT.md")"
assert_contains "PROJECT_CONTEXT.md has location [app root]" "$PC_CONTENT" "[app root]"

# (v) Integrate writes restart_server.sh (no rpc-cmd — local-dev only)
RESTART_NO_RPC_CWD="$BASE_TMP/restart_no_rpc_test"
mkdir -p "$RESTART_NO_RPC_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$RESTART_NO_RPC_CWD" --slug=test-restart-nopc
assert_file_exists "integrate writes restart_server.sh (no rpc)" "$RESTART_NO_RPC_CWD/restart_server.sh"
RESTART_NO_RPC_CONTENT="$(cat "$RESTART_NO_RPC_CWD/restart_server.sh")"
assert_contains "restart_server.sh (no rpc) has local hint" "$RESTART_NO_RPC_CONTENT" "start your server manually"

# (w) Integrate writes restart_server.sh (with --restart-rpc-cmd)
RESTART_RPC_CWD="$BASE_TMP/restart_rpc_test"
mkdir -p "$RESTART_RPC_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$RESTART_RPC_CWD" --slug=test-restart-rpc \
    --restart-rpc-cmd="some_rpc_restart_call --app test"
assert_file_exists "integrate writes restart_server.sh (with rpc)" "$RESTART_RPC_CWD/restart_server.sh"
RESTART_RPC_CONTENT="$(cat "$RESTART_RPC_CWD/restart_server.sh")"
assert_contains "restart_server.sh (with rpc) has rpc cmd" "$RESTART_RPC_CONTENT" "some_rpc_restart_call --app test"

# (x) Static Makefile has ci: target after integrate
STATIC_CI_CWD="$BASE_TMP/static_ci_test"
mkdir -p "$STATIC_CI_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$STATIC_CI_CWD" --slug=test-ci
CI_COUNT=$(grep -c '^ci:' "$STATIC_CI_CWD/Makefile" || true)
check "static integrate creates ci: Makefile target" "1" "$CI_COUNT"

# (y) Static ci: is idempotent (second integrate doesn't duplicate)
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$STATIC_CI_CWD" --slug=test-ci
CI_COUNT_AFTER=$(grep -c '^ci:' "$STATIC_CI_CWD/Makefile" || true)
check "static ci: idempotent after re-run" "1" "$CI_COUNT_AFTER"

# (z) Phoenix integrate writes usage_rules_INDEX.md
USAGE_RULES_CWD="$BASE_TMP/usage_rules_test"
mkdir -p "$USAGE_RULES_CWD/codegen"
"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$USAGE_RULES_CWD" --slug=test-usage
assert_file_exists "phoenix integrate writes codegen/usage_rules_INDEX.md" \
    "$USAGE_RULES_CWD/codegen/usage_rules_INDEX.md"

# (aa) Static integrate does NOT write usage_rules_INDEX.md
STATIC_NO_USAGE_CWD="$BASE_TMP/static_no_usage_test"
mkdir -p "$STATIC_NO_USAGE_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$STATIC_NO_USAGE_CWD" --slug=test-no-usage
if [[ -f "$STATIC_NO_USAGE_CWD/codegen/usage_rules_INDEX.md" ]]; then
    printf 'FAIL: static integrate must not write codegen/usage_rules_INDEX.md\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: static integrate does not write usage_rules_INDEX.md\n'
    pass=$((pass + 1))
fi

# (ab) PROJECT_CONTEXT.md does not contain combobulate
PC_PHOENIX_CWD="$BASE_TMP/pc_phoenix_test"
mkdir -p "$PC_PHOENIX_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$PC_PHOENIX_CWD" --slug=test-pc-phoenix
if [[ -f "$PC_PHOENIX_CWD/PROJECT_CONTEXT.md" ]]; then
    PC_PHOENIX_CONTENT="$(cat "$PC_PHOENIX_CWD/PROJECT_CONTEXT.md")"
    PC_COMBOBULATE="$(printf '%s' "$PC_PHOENIX_CONTENT" | grep -i "combobulate" || true)"
    check "phoenix PROJECT_CONTEXT.md has no combobulate" "" "$PC_COMBOBULATE"
fi

# (ac) PROJECT_CONTEXT.md is idempotent (second integrate doesn't overwrite)
FIRST_PC_CONTENT="$(cat "$PC_PHOENIX_CWD/PROJECT_CONTEXT.md")"
"$CODEGEN_SCAFFOLD" integrate --stack=phoenix --cwd="$PC_PHOENIX_CWD" --slug=test-pc-phoenix
SECOND_PC_CONTENT="$(cat "$PC_PHOENIX_CWD/PROJECT_CONTEXT.md")"
check "PROJECT_CONTEXT.md idempotent after re-run" "$FIRST_PC_CONTENT" "$SECOND_PC_CONTENT"

# (ad) --recipe-source plants codegen/recipes-extra symlink AND keeps generic codegen/recipes
RECIPE_SOURCE_CWD="$BASE_TMP/recipe_source_test"
RECIPE_SOURCE_DIR="$BASE_TMP/external_recipes"
mkdir -p "$RECIPE_SOURCE_CWD" "$RECIPE_SOURCE_DIR"
printf '# Extra recipes\n' >"$RECIPE_SOURCE_DIR/INDEX.md"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$RECIPE_SOURCE_CWD" --slug=test-recipe-src \
    --recipe-source="$RECIPE_SOURCE_DIR"
if [[ -L "$RECIPE_SOURCE_CWD/codegen/recipes-extra" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: codegen/recipes-extra is a symlink\n'
    pass=$((pass + 1))
else
    printf 'FAIL: codegen/recipes-extra is not a symlink\n'
    fail=$((fail + 1))
fi
assert_file_exists "recipes-extra/INDEX.md resolves via symlink" "$RECIPE_SOURCE_CWD/codegen/recipes-extra/INDEX.md"
# generic recipes symlink STILL present (append, not replace)
if [[ -L "$RECIPE_SOURCE_CWD/codegen/recipes" ]]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: generic codegen/recipes still present\n'
    pass=$((pass + 1))
else
    printf 'FAIL: generic codegen/recipes missing after --recipe-source\n'
    fail=$((fail + 1))
fi
assert_file_exists "generic recipes/INDEX.md still resolves" "$RECIPE_SOURCE_CWD/codegen/recipes/INDEX.md"

# (ae) no --recipe-source → recipes-extra absent (default behavior unchanged)
NO_RECIPE_SOURCE_CWD="$BASE_TMP/no_recipe_source_test"
mkdir -p "$NO_RECIPE_SOURCE_CWD"
"$CODEGEN_SCAFFOLD" integrate --stack=static --cwd="$NO_RECIPE_SOURCE_CWD" --slug=test-no-recipe-src
if [[ -e "$NO_RECIPE_SOURCE_CWD/codegen/recipes-extra" ]]; then
    printf 'FAIL: recipes-extra created without --recipe-source flag\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: no recipes-extra without flag\n'
    pass=$((pass + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$pass" "$fail"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
