#!/usr/bin/env bash
# repo-format_test.sh — unit tests for repo-format.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/repo-format.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        printf 'FAIL: %s\n  expected not to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
BIN="$TMP/bin"
mkdir -p "$REPO" "$BIN"

printf '%s\n' '#!/usr/bin/env bash' 'printf "shfmt:%s\n" "$@" >>"$FORMAT_LOG"' >"$BIN/shfmt"
chmod +x "$BIN/shfmt"

printf '%s\n' '#!/usr/bin/env bash' 'printf "npx:%s\n" "$@" >>"$FORMAT_LOG"' >"$BIN/npx"
chmod +x "$BIN/npx"

(
    cd "$REPO"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'ignored/\n' >.gitignore
    printf '#!/usr/bin/env bash\necho tracked\n' >tracked.sh
    printf 'echo extensionless\n' >"script with space"
    printf '#!/usr/bin/env bash\n<%%= invalid_until_rendered %%>\n' >template.sh.eex
    printf '{"a":1}\n' >data.json
    mkdir -p ignored
    printf '{"ignored":true}\n' >ignored/generated.json
    git add .gitignore tracked.sh "script with space" template.sh.eex data.json
    git commit -qm init
    printf '{"b":2}\n' >"new file.json"
    mkdir -p empty_dir
)

FORMAT_LOG="$TMP/format.log" PATH="$BIN:$PATH" "$LIB" "$REPO"
LOG=$(LC_ALL=C sort "$TMP/format.log")

assert_contains "tracked shell file sent to shfmt" "tracked.sh" "$LOG"
assert_contains "extensionless shell shebang sent to shfmt" "script with space" "$LOG"
assert_contains "tracked json sent to prettier" "data.json" "$LOG"
assert_not_contains "shell-looking EEx template skipped by shfmt" "shfmt:template.sh.eex" "$LOG"
assert_contains "untracked nonignored file sent to prettier" "new file.json" "$LOG"
assert_not_contains "untracked directories skipped" "empty_dir" "$LOG"
assert_contains "prettier ignores unsupported paths instead of erroring" "--ignore-unknown" "$LOG"
assert_not_contains "ignored generated file skipped" "ignored/generated.json" "$LOG"

FORMAT_EXCLUDE_LOG="$TMP/exclude.log"
CODEGEN_FORMAT_EXCLUDE=$'tracked.sh\nscript with space' FORMAT_LOG="$FORMAT_EXCLUDE_LOG" PATH="$BIN:$PATH" "$LIB" "$REPO"
EXCLUDE_LOG=$(LC_ALL=C sort "$FORMAT_EXCLUDE_LOG")

assert_not_contains "explicit exclude skips tracked shell file" "tracked.sh" "$EXCLUDE_LOG"
assert_not_contains "explicit exclude skips path with spaces" "script with space" "$EXCLUDE_LOG"
assert_contains "other files still format when excludes are present" "data.json" "$EXCLUDE_LOG"

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
