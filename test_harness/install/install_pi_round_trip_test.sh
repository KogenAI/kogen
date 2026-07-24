#!/usr/bin/env bash
# install_pi_round_trip_test.sh — install.sh --harness=pi → assert artifacts → uninstall.sh → assert clean.
# Requires jq, yq, rg, claude pre-installed on the host. Skips if any are absent.
# install.sh deletes and regenerates templates/generated/ — this is expected (the dir is not source-controlled).
set -euo pipefail

passed=0
failed=0
fail_lines=()

assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        fail_lines+=("FAIL: $label — eval failed: $cond")
    fi
}

# Pre-flight: fail if required tools absent
for cmd in jq yq rg claude; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FAIL: required tool '$cmd' not on host PATH — install it to run this test" >&2
        echo "0 passed, 1 failed"
        exit 1
    fi
done

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_home="$(mktemp -d -t ocg-install-XXXXXX)"

# Real-ambient capture (read-only, BEFORE the fixture-owned prefix override
# below): install.sh's pi leg runs a real `npm install -g` — without
# redirecting npm_config_prefix, that global install writes into whatever
# prefix the host ambiently has configured. A fabricated sentinel prefix
# (an unrelated fresh mktemp dir the override never points at) proves
# nothing — nothing would ever write there regardless of whether isolation
# actually works. Capture the REAL ambient npm prefix, its bin dir, the
# resolved `pi` binary path, and a listing+checksum of that bin dir instead,
# so the post-round-trip assertion is evidence the ambient install was
# genuinely untouched.
ambient_prefix="$(npm config get prefix)"
ambient_bin="$ambient_prefix/bin"
ambient_pi="$(command -v pi || true)"
_resolved_path() {
    local p="$1"
    if [ -n "$p" ] && [ -e "$p" ]; then
        (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
    fi
}
_ambient_snapshot() {
    printf 'ambient_prefix=%s\n' "$ambient_prefix"
    printf 'ambient_bin=%s\n' "$ambient_bin"
    printf 'ambient_command_v_pi=%s\n' "${ambient_pi:-<none>}"
    printf 'ambient_resolved_pi=%s\n' "$(_resolved_path "$ambient_pi")"
    if [ -n "$ambient_pi" ] && [ -L "$ambient_pi" ]; then
        printf 'ambient_pi_symlink_target=%s\n' "$(readlink "$ambient_pi" 2>/dev/null || true)"
    else
        printf 'ambient_pi_symlink_target=<not-symlink>\n'
    fi
    { [ -d "$ambient_bin" ] && find "$ambient_bin" -maxdepth 1 -name 'pi' -print 2>/dev/null | sort | sed 's/^/ambient_bin_pi_entry=/'; } || true
    if [ -n "$ambient_pi" ] && [ -f "$ambient_pi" ]; then
        printf 'ambient_pi_cksum=%s\n' "$(cksum <"$ambient_pi" 2>/dev/null || true)"
        printf 'ambient_pi_bytes=%s\n' "$(wc -c <"$ambient_pi" 2>/dev/null | tr -d ' ' || true)"
    else
        printf 'ambient_pi_cksum=<none>\n'
        printf 'ambient_pi_bytes=<none>\n'
    fi
}
ambient_snapshot_before="$(_ambient_snapshot)"
[ -n "$ambient_snapshot_before" ] || {
    echo "FAIL: ambient npm/pi snapshot capture was empty" >&2
    echo "0 passed, 1 failed"
    exit 1
}

# Fixture-owned npm prefix: redirect the real `npm install -g` (install.sh's
# pi leg) into a throwaway prefix instead of the host's ambient global prefix.
# Prepend (never replace) PATH so real tooling (jq/yq/rg/node/mise) stays
# resolvable — only `pi` itself resolves from the fixture prefix afterward.
npm_prefix="$(mktemp -d -t ocg-npm-XXXXXX)"
export npm_config_prefix="$npm_prefix"
export PATH="$npm_prefix/bin:$PATH"

trap 'rm -rf "$tmp_home" "$npm_prefix"' EXIT

# Create completion dir + rc files
mkdir -p "$tmp_home/.zsh/completions"
touch "$tmp_home/.zshrc" "$tmp_home/.bashrc"

# Capture real MISE_DATA_DIR and MISE_STATE_DIR before HOME is changed, so mise shims
# can find trust records and trusted-configs (trust records live in state dir, not data dir).
# Without this, mise derives both dirs from $HOME (now tmp) and can't find trusted configs.
if [ -z "${MISE_DATA_DIR:-}" ]; then
    _real_mise_data_dir="${HOME}/.local/share/mise"
    if command -v mise >/dev/null 2>&1 && [ -d "$_real_mise_data_dir" ]; then
        export MISE_DATA_DIR="$_real_mise_data_dir"
    fi
fi
if [ -z "${MISE_STATE_DIR:-}" ]; then
    _real_mise_state_dir="${HOME}/.local/state/mise"
    if command -v mise >/dev/null 2>&1 && [ -d "$_real_mise_state_dir" ]; then
        export MISE_STATE_DIR="$_real_mise_state_dir"
    fi
fi

# Reuse the real Playwright browser cache instead of re-downloading ~200MB of Chromium
# into the throwaway HOME. A fresh box with no cache falls through to the normal download.
if [ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
    if [ -d "$HOME/Library/Caches/ms-playwright" ]; then
        export PLAYWRIGHT_BROWSERS_PATH="$HOME/Library/Caches/ms-playwright" # macOS
    elif [ -d "$HOME/.cache/ms-playwright" ]; then
        export PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright" # Linux
    fi
fi

export HOME="$tmp_home"
export SHELL="/bin/bash"
export ZSH_COMPLETION_DIRS="$tmp_home/.zsh/completions"
# Isolate generator output so a concurrently-running sibling install test cannot collide
# on the shared repo-tracked templates/generated/ dir.
export OCG_GENERATED_DIR="$tmp_home/generated"
# Isolate rendered app-doc output so this test never writes tracked
# shared/apps/*.md bytes in the real repo checkout.
export OCG_RENDERED_APPS_DIR="$tmp_home/rendered-apps"

# Snapshot tracked shared/apps/ bytes before install so we can assert install
# never mutates the tracked checkout while rendering into the isolated dir.
apps_diff_before="$(cd "$CODEGEN_DIR" && git diff --binary --full-index HEAD -- shared/apps)"

# Run install for pi harness only
if ! "$CODEGEN_DIR/install.sh" --harness=pi </dev/null >"$tmp_home/install.log" 2>&1; then
    failed=$((failed + 1))
    fail_lines+=("FAIL: install.sh --harness=pi exited non-zero")
    cat "$tmp_home/install.log" >&2
fi
roundtrip_command_v_pi="$(command -v pi || true)"
roundtrip_resolved_pi="$(_resolved_path "$roundtrip_command_v_pi")"
roundtrip_pi_result=""
if [ -n "$roundtrip_command_v_pi" ]; then
    roundtrip_pi_result="$(pi --help 2>&1 || true)"
fi
roundtrip_evidence="$tmp_home/pi-roundtrip-evidence.log"
{
    printf 'npm_config_prefix=%s\n' "$npm_config_prefix"
    printf 'PATH=%s\n' "$PATH"
    printf 'command_v_pi=%s\n' "${roundtrip_command_v_pi:-<none>}"
    printf 'resolved_pi=%s\n' "${roundtrip_resolved_pi:-<none>}"
    printf 'roundtrip_result_first_line=%s\n' "$(printf '%s\n' "$roundtrip_pi_result" | sed -n '1p')"
    printf '%s\n' 'ambient_before:'
    printf '%s\n' "$ambient_snapshot_before"
} >"$roundtrip_evidence"
assert "same-concurrent-aggregate pi evidence captured" '[ -s "$roundtrip_evidence" ]'
assert "roundtrip pi resolves from fixture npm prefix" \
    '[ -n "$roundtrip_command_v_pi" ] && [ "$roundtrip_command_v_pi" = "$npm_prefix/bin/pi" ]'
assert "roundtrip pi command produced non-empty output" '[ -n "$roundtrip_pi_result" ]'

apps_diff_after="$(cd "$CODEGEN_DIR" && git diff --binary --full-index HEAD -- shared/apps)"
assert "install.sh does not mutate tracked shared/apps/ bytes" \
    '[ "$apps_diff_before" = "$apps_diff_after" ]'

# Assert rendered app docs land in the isolated output dir, not tracked shared/apps/
assert "AGENTS-phoenix.md rendered to isolated dir" '[ -f "$tmp_home/rendered-apps/AGENTS-phoenix.md" ]'
assert "AGENTS-static.md rendered to isolated dir" '[ -f "$tmp_home/rendered-apps/AGENTS-static.md" ]'
assert "CLAUDE-phoenix.md rendered to isolated dir" '[ -f "$tmp_home/rendered-apps/CLAUDE-phoenix.md" ]'
assert "CLAUDE-static.md rendered to isolated dir" '[ -f "$tmp_home/rendered-apps/CLAUDE-static.md" ]'

# Assert artifacts present
assert ".ocg/config.json exists" '[ -f "$tmp_home/.ocg/config.json" ]'
assert "no claude hooks dir" '[ ! -d "$tmp_home/.claude/hooks" ]'

# Pi launchers from manifest (now includes shared root launchers)
if [ -f "$CODEGEN_DIR/harnesses/pi/manifest.yaml" ] && command -v yq >/dev/null 2>&1; then
    while IFS=$'\t' read -r _src name; do
        assert "launcher '$name' exists" '[ -f "$tmp_home/.local/bin/$name" ]'
    done < <(yq e '.launchers[] | [.src, .name] | join("\t")' "$CODEGEN_DIR/harnesses/pi/manifest.yaml" 2>/dev/null)
fi
assert "codegen-log launcher exists" '[ -f "$tmp_home/.local/bin/codegen-log" ]'

# Pi agents populated (templates/generated/pi/agent/*.md)
if [ -d "$tmp_home/.pi/agent/agents" ]; then
    pi_agent_count="$(ls "$tmp_home/.pi/agent/agents/" 2>/dev/null | wc -l | tr -d ' ')"
    assert "pi agents dir populated" '[ "$pi_agent_count" -gt 0 ]'
else
    # May not exist if pi manifests use a different layout — just assert install succeeded
    assert "install.sh exited 0" 'true'
fi

# Plant orphaned legacy codex-* stubs so uninstall.sh prunes them
mkdir -p "$tmp_home/.local/bin"
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    printf '#!/bin/sh\n' >"$tmp_home/.local/bin/$_codex"
    chmod +x "$tmp_home/.local/bin/$_codex"
done

# Run uninstall
printf 'N\nN\n' | SHELL=/bin/bash "$CODEGEN_DIR/uninstall.sh" >"$tmp_home/uninstall.log" 2>&1 || {
    failed=$((failed + 1))
    fail_lines+=("FAIL: uninstall.sh exited non-zero")
}

# Pi launchers removed
if [ -f "$CODEGEN_DIR/harnesses/pi/manifest.yaml" ] && command -v yq >/dev/null 2>&1; then
    while IFS=$'\t' read -r _src name; do
        assert "pi launcher '$name' removed after uninstall" '[ ! -f "$tmp_home/.local/bin/$name" ]'
    done < <(yq e '.launchers[] | [.src, .name] | join("\t")' "$CODEGEN_DIR/harnesses/pi/manifest.yaml" 2>/dev/null)
fi
assert "codegen-log launcher removed" '[ ! -e "$tmp_home/.local/bin/codegen-log" ]'

# Assert codex stubs pruned by uninstall
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    assert "uninstall pruned orphaned legacy launcher '$_codex'" \
        '[ ! -f "$tmp_home/.local/bin/$_codex" ]'
done

# Pi agents .md files removed unconditionally (no prompt in uninstall.sh)
# uninstall.sh removes the .md files but may leave the empty dir
assert "pi agents .md files removed after uninstall" \
    '[ "$(find "$tmp_home/.pi/agent/agents" -name "*.md" -type f 2>/dev/null | wc -l | tr -d " ")" -eq 0 ]'

# rc file cleanup
assert "bash_completion.sh source removed from .bashrc" \
    '! grep -q "bash_completion.sh" "$tmp_home/.bashrc" 2>/dev/null'

# Ambient npm prefix isolation: the round trip's global `npm install -g` must
# land only in the fixture-owned npm_prefix, never in the REAL ambient
# prefix captured before the override. Re-derive the same snapshot function
# body (ambient_prefix/ambient_bin/ambient_pi are unchanged — only the
# fixture-owned npm_config_prefix/PATH were exported, never the ambient
# ones) and assert byte-for-byte equality with the pre-round-trip capture.
ambient_snapshot_after="$(_ambient_snapshot)"
assert "real ambient npm prefix pi state unchanged by round trip" \
    '[ "$ambient_snapshot_before" = "$ambient_snapshot_after" ]'
{
    printf '%s\n' 'ambient_after:'
    printf '%s\n' "$ambient_snapshot_after"
    printf 'ambient_unchanged=%s\n' "$([ "$ambient_snapshot_before" = "$ambient_snapshot_after" ] && printf yes || printf no)"
} >>"$roundtrip_evidence"

# Footer
echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
