#!/usr/bin/env bash
# install_claude_round_trip_test.sh — install.sh --harness=claude → assert artifacts → uninstall.sh → assert clean.
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

# Pre-flight: fail if required tools absent (brew/curl side-effects escape HOME)
for cmd in jq yq rg claude; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FAIL: required tool '$cmd' not on host PATH — install it to run this test" >&2
        echo "0 passed, 1 failed"
        exit 1
    fi
done

CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_home="$(mktemp -d -t ocg-install-XXXXXX)"
trap 'rm -rf "$tmp_home"' EXIT

# Create completion dir so install.sh picks it FIRST (before /opt/homebrew which may be writable)
mkdir -p "$tmp_home/.zsh/completions"
# Pre-create rc files so uninstall.sh can clean them
touch "$tmp_home/.zshrc" "$tmp_home/.bashrc"

# Capture real MISE_DATA_DIR before HOME is changed, so mise shims can find trust records.
# Without this, mise derives data dir from $HOME (now tmp) and can't find trusted configs.
if [ -z "${MISE_DATA_DIR:-}" ]; then
    _real_mise_data_dir="${HOME}/.local/share/mise"
    if command -v mise >/dev/null 2>&1 && [ -d "$_real_mise_data_dir" ]; then
        export MISE_DATA_DIR="$_real_mise_data_dir"
    fi
fi

export HOME="$tmp_home"
export SHELL="/bin/bash"
# Redirect completion dirs to tmp_home so install.sh stays fully hermetic
export ZSH_COMPLETION_DIRS="$tmp_home/.zsh/completions"

# Run install (single-harness skips the interactive prompt path)
if ! "$CODEGEN_DIR/install.sh" --harness=claude </dev/null >"$tmp_home/install.log" 2>&1; then
    failed=$((failed + 1))
    fail_lines+=("FAIL: install.sh --harness=claude exited non-zero")
    cat "$tmp_home/install.log" >&2
fi

# Assert artifacts present
assert "settings.json exists" '[ -f "$tmp_home/.claude/settings.json" ]'
assert ".ocg/config.json exists" '[ -f "$tmp_home/.ocg/config.json" ]'
assert "hooks dir populated" '[ "$(ls "$tmp_home/.claude/hooks" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
assert "hooks/lib dir populated" '[ "$(ls "$tmp_home/.claude/hooks/lib" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
assert "agents dir populated" '[ "$(ls "$tmp_home/.claude/agents" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
assert "no pi launchers present" '[ ! -f "$tmp_home/.local/bin/pi-build" ]'
assert "codegen-log launcher exists" '[ -f "$tmp_home/.local/bin/codegen-log" ]'

# Claude-specific launcher(s) from manifest
if [ -f "$CODEGEN_DIR/harnesses/claude/manifest.yaml" ] && command -v yq >/dev/null 2>&1; then
    while IFS=$'\t' read -r _src name; do
        assert "launcher '$name' exists" '[ -f "$tmp_home/.local/bin/$name" ]'
    done < <(yq e '.launchers[] | [.src, .name] | join("\t")' "$CODEGEN_DIR/harnesses/claude/manifest.yaml" 2>/dev/null)
fi

# Assert hook tree matches source (spot-check count)
hook_src_count="$(find "$CODEGEN_DIR/harnesses/claude/hooks" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d ' ')"
hook_dst_count="$(find "$tmp_home/.claude/hooks" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert "hook count matches source ($hook_src_count hooks)" '[ "$hook_src_count" -eq "$hook_dst_count" ]'

# Assert dispatch symlink wired
assert "harnesses dispatch symlink exists" '[ -L "$tmp_home/.local/bin/harnesses" ]'
assert "harnesses dispatch symlink resolves to claude/" '[ -d "$tmp_home/.local/bin/harnesses/claude" ]'

# Assert platform symlinks wired in CODEGEN_DIR/codegen/
assert "codegen/rules platform symlink resolves" '[ -e "$CODEGEN_DIR/codegen/rules/INDEX.md" ]'
assert "codegen/recipes platform symlink resolves" '[ -e "$CODEGEN_DIR/codegen/recipes/INDEX.md" ]'
assert "codegen/usage_rules platform symlink resolves" '[ -e "$CODEGEN_DIR/codegen/usage_rules/INDEX.md" ]'
assert "codegen/subagents platform symlink resolves" '[ -e "$CODEGEN_DIR/codegen/subagents" ]'

# Assert non-interactive run with OCG_DEFAULT_AGENT exits 0
# config.json already written by first run — delete it so the second run hits the selection path
rm -f "$tmp_home/.ocg/config.json"
# Plant orphaned legacy codex-* stubs so second install.sh prunes them
mkdir -p "$tmp_home/.local/bin"
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    printf '#!/bin/sh\n' >"$tmp_home/.local/bin/$_codex"
    chmod +x "$tmp_home/.local/bin/$_codex"
done
if ! OCG_DEFAULT_AGENT=claude OCG_NONINTERACTIVE=1 "$CODEGEN_DIR/install.sh" --harness=claude </dev/null >"$tmp_home/install2.log" 2>&1; then
    failed=$((failed + 1))
    fail_lines+=("FAIL: non-interactive install.sh exited non-zero")
    cat "$tmp_home/install2.log" >&2
fi
assert "non-interactive run sets default_agent=claude" \
    '[ "$(jq -r .default_agent "$tmp_home/.ocg/config.json" 2>/dev/null)" = "claude" ]'
# Assert codex stubs pruned by install
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    assert "install pruned orphaned legacy launcher '$_codex'" \
        '[ ! -f "$tmp_home/.local/bin/$_codex" ]'
done

# Plant orphaned legacy codex-* stubs again so uninstall.sh prunes them
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    printf '#!/bin/sh\n' >"$tmp_home/.local/bin/$_codex"
    chmod +x "$tmp_home/.local/bin/$_codex"
done

# Run uninstall (answer N to both prompts → keep claude data tree)
printf 'N\nN\n' | SHELL=/bin/bash "$CODEGEN_DIR/uninstall.sh" >"$tmp_home/uninstall.log" 2>&1 || {
    failed=$((failed + 1))
    fail_lines+=("FAIL: uninstall.sh exited non-zero")
}

# Assert removals — ocg symlink removed (uninstall.sh always removes it)
assert "ocg symlink removed" '[ ! -e "$tmp_home/.local/bin/ocg" ]'
assert "codegen-log launcher removed" '[ ! -e "$tmp_home/.local/bin/codegen-log" ]'

# Assert codex stubs pruned by uninstall
for _codex in codex-build codex-inspector codex-refactor codex-shape; do
    assert "uninstall pruned orphaned legacy launcher '$_codex'" \
        '[ ! -f "$tmp_home/.local/bin/$_codex" ]'
done

# Note: claude-specific launchers (claude-build, etc.) are NOT removed by uninstall.sh
# (only the ocg symlink and pi launchers are removed). This is current behavior.

# Claude data preserved (answered N)
assert ".claude data tree preserved after N to prompt" '[ -d "$tmp_home/.claude" ]'

# Completion line removed from rc file
assert "bash_completion.sh source removed from .bashrc" \
    '! grep -q "bash_completion.sh" "$tmp_home/.bashrc" 2>/dev/null'

# Footer
echo "$passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    printf '%s\n' "${fail_lines[@]}" >&2
    exit 1
fi
