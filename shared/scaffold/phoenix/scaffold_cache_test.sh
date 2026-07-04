#!/usr/bin/env bash
# scaffold_cache_test.sh — hermetic unit tests for scaffold_cache.sh
# No mix, no LLM, no real ~/.cache writes ($XDG_CACHE_HOME redirected to tmpdir).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./scaffold_cache.sh
source "$SCRIPT_DIR/scaffold_cache.sh"

passed=0
failed=0
fail_lines=()

assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        fail_lines+=("FAIL: $label")
    fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-cache-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

export XDG_CACHE_HOME="$tmp/xdg-cache"

# ---------------------------------------------------------------------------
# scaffold_cache_root honors $XDG_CACHE_HOME
# ---------------------------------------------------------------------------
root="$(scaffold_cache_root)"
assert "cache root honors XDG_CACHE_HOME" '[ "$root" = "$tmp/xdg-cache/codegen-scaffold" ]'

# ---------------------------------------------------------------------------
# Key determinism + sensitivity
# ---------------------------------------------------------------------------
target_a="$tmp/target-a"
mkdir -p "$target_a"
echo 'lock-content-v1' >"$target_a/mix.lock"

key_a1="$(scaffold_cache_key "$target_a" "28.4.1" "1.19.5")"
key_a2="$(scaffold_cache_key "$target_a" "28.4.1" "1.19.5")"
assert "key determinism: identical mix.lock -> identical key" '[ "$key_a1" = "$key_a2" ]'

target_b="$tmp/target-b"
mkdir -p "$target_b"
echo 'lock-content-v2-different' >"$target_b/mix.lock"
key_b="$(scaffold_cache_key "$target_b" "28.4.1" "1.19.5")"
assert "key sensitivity: differing mix.lock -> different key" '[ "$key_a1" != "$key_b" ]'

key_a_diff_otp="$(scaffold_cache_key "$target_a" "27.0.0" "1.19.5")"
assert "key sensitivity: differing otp -> different key" '[ "$key_a1" != "$key_a_diff_otp" ]'

key_a_diff_elixir="$(scaffold_cache_key "$target_a" "28.4.1" "1.18.0")"
assert "key sensitivity: differing elixir -> different key" '[ "$key_a1" != "$key_a_diff_elixir" ]'

# mix.lock absent -> non-zero, key not computable
target_nolock="$tmp/target-nolock"
mkdir -p "$target_nolock"
nolock_rc=0
scaffold_cache_key "$target_nolock" "28.4.1" "1.19.5" >/dev/null 2>&1 || nolock_rc=$?
assert "key computation fails when mix.lock absent" '[ "$nolock_rc" -ne 0 ]'

# ---------------------------------------------------------------------------
# restore: miss -> non-zero, target untouched
# ---------------------------------------------------------------------------
cache_root="$tmp/cache-root"
restore_target="$tmp/restore-target-miss"
mkdir -p "$restore_target"
miss_rc=0
scaffold_cache_restore "$restore_target" "$cache_root" "nonexistent-key" >/dev/null 2>&1 || miss_rc=$?
assert "restore miss returns non-zero" '[ "$miss_rc" -ne 0 ]'
assert "restore miss leaves target untouched (no deps dir)" '[ ! -e "$restore_target/deps" ]'

# ---------------------------------------------------------------------------
# restore: hit -> copies deps/, _build/dev/lib/foo, _build/test/lib/foo,
# priv/plts/dialyzer.plt into target
# ---------------------------------------------------------------------------
hit_key="hit-key-1"
entry="$cache_root/$hit_key"
mkdir -p "$entry/deps/foo"
echo 'dep-foo-content' >"$entry/deps/foo/mix.exs"
mkdir -p "$entry/_build/dev/lib/foo"
echo 'dev-foo-beam' >"$entry/_build/dev/lib/foo/foo.app"
mkdir -p "$entry/_build/test/lib/foo"
echo 'test-foo-beam' >"$entry/_build/test/lib/foo/foo.app"
echo 'plt-bytes' >"$entry/dialyzer.plt"

restore_target_hit="$tmp/restore-target-hit"
mkdir -p "$restore_target_hit"
hit_rc=0
scaffold_cache_restore "$restore_target_hit" "$cache_root" "$hit_key" >/dev/null 2>&1 || hit_rc=$?
assert "restore hit returns zero" '[ "$hit_rc" -eq 0 ]'
assert "restore hit copies deps/foo" '[ -f "$restore_target_hit/deps/foo/mix.exs" ]'
assert "restore hit copies _build/dev/lib/foo" '[ -f "$restore_target_hit/_build/dev/lib/foo/foo.app" ]'
assert "restore hit copies _build/test/lib/foo" '[ -f "$restore_target_hit/_build/test/lib/foo/foo.app" ]'
assert "restore hit copies priv/plts/dialyzer.plt" '[ -f "$restore_target_hit/priv/plts/dialyzer.plt" ]'

# ---------------------------------------------------------------------------
# save: excludes app's own _build/*/lib/<app_name> but includes dep dirs
# ---------------------------------------------------------------------------
save_target="$tmp/save-target"
mkdir -p "$save_target/deps/bar"
echo 'dep-bar-content' >"$save_target/deps/bar/mix.exs"
mkdir -p "$save_target/_build/dev/lib/bar"
echo 'dev-bar-beam' >"$save_target/_build/dev/lib/bar/bar.app"
mkdir -p "$save_target/_build/dev/lib/my_app"
echo 'app-own-beam-must-not-be-cached' >"$save_target/_build/dev/lib/my_app/my_app.app"
mkdir -p "$save_target/priv/plts"
echo 'save-plt-bytes' >"$save_target/priv/plts/dialyzer.plt"

save_cache_root="$tmp/save-cache-root"
save_key="save-key-1"
scaffold_cache_save "$save_target" "$save_cache_root" "$save_key" "my_app"

save_entry="$save_cache_root/$save_key"
assert "save includes dep dir (bar)" '[ -f "$save_entry/_build/dev/lib/bar/bar.app" ]'
assert "save excludes app own build dir (my_app)" '[ ! -e "$save_entry/_build/dev/lib/my_app" ]'
assert "save includes deps/bar" '[ -f "$save_entry/deps/bar/mix.exs" ]'
assert "save includes dialyzer.plt" '[ -f "$save_entry/dialyzer.plt" ]'

# ---------------------------------------------------------------------------
# save atomicity: no <key>.tmp* residue, final <key>/ present
# ---------------------------------------------------------------------------
tmp_residue_count="$(find "$save_cache_root" -maxdepth 1 -name "${save_key}.tmp.*" 2>/dev/null | wc -l | tr -d ' ')"
assert "save leaves no .tmp residue" '[ "$tmp_residue_count" -eq 0 ]'
assert "save final entry dir present" '[ -d "$save_entry" ]'

# ---------------------------------------------------------------------------
# disable sentinel -> is_disabled true -> restore skipped
# ---------------------------------------------------------------------------
disable_root="$tmp/disable-root"
disable_key="disable-key-1"
mkdir -p "$disable_root/$disable_key/deps"
scaffold_cache_disable "$disable_root" "$disable_key"

assert "is_disabled true after disable" 'scaffold_cache_is_disabled "$disable_root" "$disable_key"'

disable_restore_target="$tmp/disable-restore-target"
mkdir -p "$disable_restore_target"
disabled_restore_rc=0
scaffold_cache_restore "$disable_restore_target" "$disable_root" "$disable_key" >/dev/null 2>&1 || disabled_restore_rc=$?
assert "restore skipped when disabled" '[ "$disabled_restore_rc" -ne 0 ]'
assert "restore skipped leaves target untouched" '[ ! -e "$disable_restore_target/deps" ]'

# is_disabled false when no sentinel present
not_disabled_rc=0
scaffold_cache_is_disabled "$cache_root" "$hit_key" >/dev/null 2>&1 || not_disabled_rc=$?
assert "is_disabled false when no sentinel present" '[ "$not_disabled_rc" -ne 0 ]'

echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
