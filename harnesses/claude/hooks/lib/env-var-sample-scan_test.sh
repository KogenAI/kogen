#!/usr/bin/env bash
# env-var-sample-scan_test.sh — unit tests for env-var-sample-scan.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/env-var-sample-scan.sh"

pass=0
fail=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

assert_exit() {
    local name="$1" expected="$2" actual="$3"
    assert_eq "$name" "$expected" "$actual"
}

new_repo() {
    local dir
    dir=$(mktemp -d)
    dir=$(cd "$dir" && pwd -P)
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    printf '# sample\n' >"$dir/.env.sample"
    printf '# prod sample\n' >"$dir/.env.prod.sample"
    mkdir -p "$dir/lib"
    printf 'defmodule Foo do\nend\n' >"$dir/lib/foo.ex"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "init"
    printf "$dir\n"
}

# --- Test A: var declared in both samples → exit 0, empty stdout ---
TA=$(new_repo)
printf 'MY_VAR=set-me\n' >>"$TA/.env.sample"
printf 'MY_VAR=set-me\n' >>"$TA/.env.prod.sample"
printf 'defmodule Foo do\n  def bar, do: System.get_env("MY_VAR")\nend\n' >"$TA/lib/foo.ex"
out=$(bash "$SCAN" "$TA")
rc=$?
assert_exit "var declared in both samples → exit 0" "0" "$rc"
assert_eq "var declared in both samples → empty stdout" "" "$out"
rm -rf "$TA"

# --- Test B: var absent from .env.sample → exit 1, prints var ---
TB=$(new_repo)
printf 'MY_VAR=set-me\n' >>"$TB/.env.prod.sample"
printf 'defmodule Foo do\n  def bar, do: System.get_env("MY_VAR")\nend\n' >"$TB/lib/foo.ex"
out=$(bash "$SCAN" "$TB")
rc=$?
assert_exit "var absent from .env.sample → exit 1" "1" "$rc"
assert_eq "var absent from .env.sample → prints var" "MY_VAR" "$out"
rm -rf "$TB"

# --- Test C: var absent from .env.prod.sample only → exit 1 ---
TC=$(new_repo)
printf 'MY_VAR=set-me\n' >>"$TC/.env.sample"
printf 'defmodule Foo do\n  def bar, do: System.fetch_env("MY_VAR")\nend\n' >"$TC/lib/foo.ex"
out=$(bash "$SCAN" "$TC")
rc=$?
assert_exit "var absent from .env.prod.sample only → exit 1" "1" "$rc"
assert_eq "var absent from .env.prod.sample only → prints var" "MY_VAR" "$out"
rm -rf "$TC"

# --- Test D: no .ex/.exs changed → exit 0 ---
TD=$(new_repo)
printf 'stray content\n' >"$TD/README.md"
out=$(bash "$SCAN" "$TD")
rc=$?
assert_exit "no .ex/.exs changed → exit 0" "0" "$rc"
rm -rf "$TD"

# --- Test E: argless System.get_env() → exit 0 (nothing to look up) ---
TE=$(new_repo)
printf 'defmodule Foo do\n  def bar, do: System.get_env()\nend\n' >"$TE/lib/foo.ex"
out=$(bash "$SCAN" "$TE")
rc=$?
assert_exit "argless System.get_env() → exit 0" "0" "$rc"
rm -rf "$TE"

# --- Test F: removed line only (^- in diff) → exit 0 ---
TF=$(new_repo)
printf 'defmodule Foo do\n  def bar, do: System.get_env("SOME_VAR")\nend\n' >"$TF/lib/foo.ex"
git -C "$TF" add -A
git -C "$TF" commit -q -m "add var read"
printf 'defmodule Foo do\n  def bar, do: :ok\nend\n' >"$TF/lib/foo.ex"
out=$(bash "$SCAN" "$TF")
rc=$?
assert_exit "removed line only → exit 0" "0" "$rc"
rm -rf "$TF"

# --- Test G: non-git repo_root → exit 0 ---
TG=$(mktemp -d)
TG=$(cd "$TG" && pwd -P)
out=$(bash "$SCAN" "$TG")
rc=$?
assert_exit "non-git repo_root → exit 0" "0" "$rc"
rm -rf "$TG"

# --- Test H: absent repo_root arg → exit 0 ---
out=$(bash "$SCAN" 2>/dev/null)
rc=$?
assert_exit "absent repo_root arg → exit 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
